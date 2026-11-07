#include "CPower.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <string.h>
#include <time.h>

// MARK: - IOReport (private API, declared by hand)

typedef struct __IOReportSubscription *IOReportSubscriptionRef;

extern CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef group, CFStringRef subgroup,
                                                          uint64_t a, uint64_t b, uint64_t c);
extern IOReportSubscriptionRef IOReportCreateSubscription(void *a, CFMutableDictionaryRef desired,
                                                          CFMutableDictionaryRef *subscribed,
                                                          uint64_t channelId, CFTypeRef b);
extern CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef sub,
                                             CFMutableDictionaryRef subscribed, CFTypeRef a);
extern CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef prev, CFDictionaryRef cur, CFTypeRef a);
extern CFStringRef IOReportChannelGetChannelName(CFDictionaryRef channel);
extern CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef channel);
extern int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef channel, int32_t index);
extern void IOReportIterate(CFDictionaryRef samples, int (^callback)(CFDictionaryRef channel));

static IOReportSubscriptionRef g_sub = NULL;
static CFMutableDictionaryRef g_subscribed = NULL;
static CFDictionaryRef g_prev = NULL;
static double g_prevTime = 0;

static double now_seconds(void) {
    return (double)clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9;
}

int lanes_power_init(void) {
    if (g_sub) return 1;
    CFMutableDictionaryRef channels = IOReportCopyChannelsInGroup(CFSTR("Energy Model"), NULL, 0, 0, 0);
    if (!channels) return 0;
    g_sub = IOReportCreateSubscription(NULL, channels, &g_subscribed, 0, NULL);
    CFRelease(channels);
    if (!g_sub || !g_subscribed) { g_sub = NULL; return 0; }
    g_prev = IOReportCreateSamples(g_sub, g_subscribed, NULL);
    g_prevTime = now_seconds();
    return g_prev != NULL;
}

int lanes_power_read(lanes_power_channel *out, int max) {
    if (!g_sub || !g_prev) return -1;

    CFDictionaryRef current = IOReportCreateSamples(g_sub, g_subscribed, NULL);
    if (!current) return -1;
    double t = now_seconds();
    double dt = t - g_prevTime;

    CFDictionaryRef delta = IOReportCreateSamplesDelta(g_prev, current, NULL);
    CFRelease(g_prev);
    g_prev = current;
    g_prevTime = t;
    if (!delta) return -1;

    __block int count = 0;
    IOReportIterate(delta, ^int(CFDictionaryRef channel) {
        if (count >= max) return 0;

        char name[64] = {0};
        char unit[16] = {0};
        CFStringRef n = IOReportChannelGetChannelName(channel);
        CFStringRef u = IOReportChannelGetUnitLabel(channel);
        if (n) CFStringGetCString(n, name, sizeof(name), kCFStringEncodingUTF8);
        if (u) CFStringGetCString(u, unit, sizeof(unit), kCFStringEncodingUTF8);

        double scale = 0;
        if (strcmp(unit, "mJ") == 0) scale = 1e-3;
        else if (strcmp(unit, "uJ") == 0) scale = 1e-6;
        else if (strcmp(unit, "nJ") == 0) scale = 1e-9;
        if (scale == 0) return 0;   // not an energy channel we understand

        int64_t value = IOReportSimpleGetIntegerValue(channel, 0);
        strlcpy(out[count].name, name, sizeof(out[count].name));
        out[count].watts = dt > 0 ? ((double)value * scale) / dt : 0;
        count++;
        return 0;
    });
    CFRelease(delta);
    return count;
}

// MARK: - SMC

typedef struct { char major; char minor; char build; char reserved[1]; uint16_t release; } SMCVers;
typedef struct { uint16_t version; uint16_t length; uint32_t cpuPLimit; uint32_t gpuPLimit; uint32_t memPLimit; } SMCPLimit;
typedef struct { uint32_t dataSize; uint32_t dataType; uint8_t dataAttributes; } SMCKeyInfo;
typedef struct {
    uint32_t key;
    SMCVers vers;
    SMCPLimit pLimitData;
    SMCKeyInfo keyInfo;
    uint8_t result;
    uint8_t status;
    uint8_t data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCKeyData;

_Static_assert(sizeof(SMCKeyData) == 80, "SMCKeyData must match the kernel's layout");

#define SMC_HANDLE_EVENT 2
#define SMC_CMD_READ_BYTES 5
#define SMC_CMD_READ_KEYINFO 9
#define SMC_CMD_READ_INDEX 8
#define SMC_TYPE_FLT 0x666c7420u   /* 'flt ' */

static io_connect_t g_smc = 0;

int lanes_smc_open(void) {
    if (g_smc) return 1;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return 0;
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, &g_smc);
    IOObjectRelease(service);
    if (kr != KERN_SUCCESS) { g_smc = 0; return 0; }
    return 1;
}

static int smc_call(SMCKeyData *in, SMCKeyData *out) {
    size_t size = sizeof(SMCKeyData);
    kern_return_t kr = IOConnectCallStructMethod(g_smc, SMC_HANDLE_EVENT, in, sizeof(SMCKeyData), out, &size);
    return kr == KERN_SUCCESS && out->result == 0;
}

// Key info (type and size) never changes, so it is fetched once per key and cached.
// After that a read is a single round trip to the SMC.
#define SMC_CACHE_MAX 96
static struct { uint32_t key; SMCKeyInfo info; } g_keyCache[SMC_CACHE_MAX];
static int g_keyCacheCount = 0;

static int smc_key_info(uint32_t key, SMCKeyInfo *info) {
    for (int i = 0; i < g_keyCacheCount; i++) {
        if (g_keyCache[i].key == key) { *info = g_keyCache[i].info; return 1; }
    }
    SMCKeyData in, out;
    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    in.key = key;
    in.data8 = SMC_CMD_READ_KEYINFO;
    if (!smc_call(&in, &out)) return 0;
    if (g_keyCacheCount < SMC_CACHE_MAX) {
        g_keyCache[g_keyCacheCount].key = key;
        g_keyCache[g_keyCacheCount].info = out.keyInfo;
        g_keyCacheCount++;
    }
    *info = out.keyInfo;
    return 1;
}

static uint32_t smc_key_code(const char *key) {
    return ((uint32_t)key[0] << 24) | ((uint32_t)key[1] << 16) | ((uint32_t)key[2] << 8) | (uint32_t)key[3];
}

static void smc_code_string(uint32_t code, char out[5]) {
    out[0] = (char)(code >> 24); out[1] = (char)(code >> 16); out[2] = (char)(code >> 8); out[3] = (char)code;
    out[4] = 0;
}

int lanes_smc_read_number(const char *key, double *value, char type_out[5]) {
    if (!g_smc || !key || strlen(key) != 4) return 0;

    uint32_t k = smc_key_code(key);
    SMCKeyInfo info;
    if (!smc_key_info(k, &info)) return 0;
    if (type_out) smc_code_string(info.dataType, type_out);
    if (info.dataSize == 0 || info.dataSize > 4) return 0;

    SMCKeyData in, out;
    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    in.key = k;
    in.keyInfo.dataSize = info.dataSize;
    in.data8 = SMC_CMD_READ_BYTES;
    if (!smc_call(&in, &out)) return 0;

    switch (info.dataType) {
    case 0x666c7420u: {   /* 'flt ' little-endian float */
        if (info.dataSize != 4) return 0;
        float f;
        memcpy(&f, out.bytes, sizeof(f));
        *value = (double)f;
        return 1;
    }
    case 0x75693820u: *value = out.bytes[0]; return 1;                                   /* 'ui8 ' */
    case 0x75693136u: *value = (double)(((unsigned)out.bytes[0] << 8) | out.bytes[1]); return 1;   /* 'ui16' */
    case 0x75693332u:                                                                     /* 'ui32' */
        *value = (double)(((uint32_t)out.bytes[0] << 24) | ((uint32_t)out.bytes[1] << 16)
                          | ((uint32_t)out.bytes[2] << 8) | (uint32_t)out.bytes[3]);
        return 1;
    case 0x66706532u:                                                                     /* 'fpe2' */
        *value = (double)(((unsigned)out.bytes[0] << 8) | out.bytes[1]) / 4.0;
        return 1;
    case 0x73703738u:                                                                     /* 'sp78' */
        *value = (double)(int16_t)(((unsigned)out.bytes[0] << 8) | out.bytes[1]) / 256.0;
        return 1;
    default: return 0;
    }
}

int lanes_smc_read_float(const char *key, double *value) {
    char type[5];
    if (!lanes_smc_read_number(key, value, type)) return 0;
    return strcmp(type, "flt ") == 0;
}

int lanes_smc_key_count(void) {
    double n = 0;
    if (!lanes_smc_read_number("#KEY", &n, NULL)) return 0;
    return (int)n;
}

int lanes_smc_key_at(int index, char out[5]) {
    if (!g_smc || index < 0) return 0;
    SMCKeyData in, res;
    memset(&in, 0, sizeof(in));
    memset(&res, 0, sizeof(res));
    in.data8 = SMC_CMD_READ_INDEX;
    in.data32 = (uint32_t)index;
    if (!smc_call(&in, &res)) return 0;
    smc_code_string(res.key, out);
    return 1;
}

// MARK: - IOHID temperature sensors (private API, declared by hand)

typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEvent *IOHIDEventRef;

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef match);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);
extern CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef key);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t timeout);
extern double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

#define HID_EVENT_TEMPERATURE 15

static IOHIDEventSystemClientRef g_hid = NULL;

int lanes_hid_temps_read(lanes_temp_sensor *out, int max) {
    if (!g_hid) {
        g_hid = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        if (!g_hid) return -1;
        int page = 0xff00, usage = 5;
        CFNumberRef p = CFNumberCreate(NULL, kCFNumberIntType, &page);
        CFNumberRef u = CFNumberCreate(NULL, kCFNumberIntType, &usage);
        const void *keys[] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
        const void *vals[] = { p, u };
        CFDictionaryRef match = CFDictionaryCreate(NULL, keys, vals, 2, &kCFTypeDictionaryKeyCallBacks,
                                                   &kCFTypeDictionaryValueCallBacks);
        IOHIDEventSystemClientSetMatching(g_hid, match);
        CFRelease(match); CFRelease(p); CFRelease(u);
    }

    CFArrayRef services = IOHIDEventSystemClientCopyServices(g_hid);
    if (!services) return -1;
    int count = 0;
    for (CFIndex i = 0; i < CFArrayGetCount(services) && count < max; i++) {
        IOHIDServiceClientRef svc = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        IOHIDEventRef ev = IOHIDServiceClientCopyEvent(svc, HID_EVENT_TEMPERATURE, 0, 0);
        if (!ev) continue;
        double c = IOHIDEventGetFloatValue(ev, HID_EVENT_TEMPERATURE << 16);
        CFRelease(ev);

        char name[64] = "?";
        CFTypeRef product = IOHIDServiceClientCopyProperty(svc, CFSTR("Product"));
        if (product) {
            if (CFGetTypeID(product) == CFStringGetTypeID())
                CFStringGetCString((CFStringRef)product, name, sizeof(name), kCFStringEncodingUTF8);
            CFRelease(product);
        }
        strlcpy(out[count].name, name, sizeof(out[count].name));
        out[count].celsius = c;
        count++;
    }
    CFRelease(services);
    return count;
}
