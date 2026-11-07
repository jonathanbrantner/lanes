#ifndef CPOWER_H
#define CPOWER_H

#include <stdint.h>

// Power readings for Apple Silicon.
//  - IOReport "Energy Model": per-component energy counters (CPU, GPU, ANE, DRAM).
//    Private Apple API with no public header. Works without root. May change between macOS versions.
//  - SMC: single sensor values such as total system power. Also works without root.

typedef struct {
    char name[64];
    double watts;
} lanes_power_channel;

// Returns 1 on success. Safe to call more than once.
int lanes_power_init(void);

// Fills `out` with the average watts of each Energy Model channel since the previous call
// (the first call after init measures since init). Returns the number of channels, or -1 if
// IOReport is unavailable.
int lanes_power_read(lanes_power_channel *out, int max);

// Returns 1 if the SMC connection opened.
int lanes_smc_open(void);

// Reads a 4-character SMC key that holds a float (for example "PSTR"). Returns 1 and sets
// *value on success, 0 if the key is missing or not a float.
int lanes_smc_read_float(const char *key, double *value);

// Reads a 4-character SMC key of type flt, ui8/16/32, fpe2 or sp78 as a number. Returns 1 on
// success and, if type_out is not NULL, fills it with the key's 4-character type.
int lanes_smc_read_number(const char *key, double *value, char type_out[5]);

// SMC key enumeration (used by the powermon/tempmon prototypes to discover sensors).
int lanes_smc_key_count(void);
int lanes_smc_key_at(int index, char out[5]);

typedef struct {
    char name[64];
    double celsius;
} lanes_temp_sensor;

// Reads every IOHID temperature sensor (PMU die/calibration sensors, no root). Returns the
// number of sensors, or -1 if the sensor system is unavailable.
int lanes_hid_temps_read(lanes_temp_sensor *out, int max);

// Reads one IOHID temperature sensor whose name starts with `prefix` (for example "NAND").
// The sensor is looked up once and cached, so repeated calls are cheap. Returns 1 on success.
int lanes_hid_named_temp(const char *prefix, double *celsius);

#endif
