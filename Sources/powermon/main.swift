import Foundation
import CPower
import SystemMonitorCore

// powermon: prototype that prints every power reading this Mac exposes without root.
// Usage: powermon [--count N]

let args = CommandLine.arguments
var limit = 3
if let i = args.firstIndex(of: "--count"), i + 1 < args.count, let n = Int(args[i + 1]) { limit = n }

if args.contains("--smc-test") {
    _ = lanes_smc_open()
    for key in ["PSTR", "PDTR", "PHPC", "PMVC"] {
        var line = key + ":"
        for _ in 0..<8 {
            var v = 0.0
            line += lanes_smc_read_float(key, &v) == 1 ? String(format: " %.3f", v) : " -"
            Thread.sleep(forTimeInterval: 0.25)
        }
        print(line)
    }
    exit(0)
}

// --memory: every page counter and both ways of computing "Memory Used", to compare with Activity
// Monitor on a Mac where the number looks off.
if args.contains("--memory") {
    var stats = vm_statistics64_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
    _ = withUnsafeMutablePointer(to: &stats) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    var hostPage: vm_size_t = 0
    _ = host_page_size(mach_host_self(), &hostPage)
    let page = Double(hostPage)
    func gb(_ pages: UInt64) -> String { String(format: "%.2f GB", Double(pages) * page / 1_073_741_824) }
    let total = Double(ProcessInfo.processInfo.physicalMemory)
    print("page size \(hostPage) B (getpagesize \(getpagesize())), total \(String(format: "%.2f", total / 1_073_741_824)) GB")
    for (name, v) in [("free", UInt64(stats.free_count)), ("speculative", UInt64(stats.speculative_count)),
                      ("active", UInt64(stats.active_count)), ("inactive", UInt64(stats.inactive_count)),
                      ("wired", UInt64(stats.wire_count)), ("internal (anonymous)", UInt64(stats.internal_page_count)),
                      ("external (file-backed)", UInt64(stats.external_page_count)),
                      ("purgeable", UInt64(stats.purgeable_count)),
                      ("compressor", UInt64(stats.compressor_page_count))] {
        print(String(format: "  %-24@ %12llu pages  %@", name as NSString, v, gb(v) as NSString))
    }
    let app = UInt64(max(0, Int64(stats.internal_page_count) - Int64(stats.purgeable_count)))
    let parts = app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
    let freeNoSpec = UInt64(max(0, Int64(stats.free_count) - Int64(stats.speculative_count)))
    let byFree = UInt64(total / page) - freeNoSpec - UInt64(stats.external_page_count)
    print("Used = app + wired + compressed          \(gb(parts))")
    print("Used = total - free - file-backed (Lanes) \(gb(byFree))")
    print("Compare with Activity Monitor > Memory Used.")
    exit(0)
}

if args.contains("--processes") {
    let c = ProcessCollector()
    _ = c.sample()
    Thread.sleep(forTimeInterval: 2)
    let all = c.sample()
    print("By CPU:", all.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(5).map { "\($0.name) \(Int($0.cpuPercent))%" })
    print("By memory:", all.sorted { $0.footprintBytes > $1.footprintBytes }.prefix(6).map { "\($0.name) \($0.footprintBytes / 1_000_000) MB" })
    exit(0)
}

if args.contains("--logitech") {
    runLogitechProbe()
    exit(0)
}

if args.contains("--batteries") {
    print("Bluetooth:", DeviceBatteries.bluetooth().map { "\($0.name) \($0.parts)" })
    print("Logitech receiver:", LogitechReceiver.batteries().map { "\($0.name) \($0.parts)" })
    print("Laptop:", DeviceBatteries.laptop().map { "\($0)" } ?? "none")
    exit(0)
}

if args.contains("--cluster-probe") {
    runClusterProbe(efficiencyOnly: args.contains("--e-only"))
    exit(0)
}

// --temps: dump every IOHID temperature sensor and every SMC temperature/fan key.
if args.contains("--temps") {
    var sensors = [lanes_temp_sensor](repeating: lanes_temp_sensor(), count: 128)
    let n = Int(lanes_hid_temps_read(&sensors, 128))
    print("IOHID temperature sensors: \(n)")
    for i in 0..<max(n, 0) {
        let name = withUnsafePointer(to: &sensors[i].name) {
            $0.withMemoryRebound(to: CChar.self, capacity: 64) { String(cString: $0) }
        }
        print(String(format: "  HID  %-32@ %7.2f C", name as NSString, sensors[i].celsius))
    }
    print("SMC open:", lanes_smc_open() == 1 ? "ok" : "FAILED")
    let allKeys = SMCKeys.all()
    print("SMC keys: \(allKeys.count)")
    for key in allKeys {
        guard key.hasPrefix("T") || key.hasPrefix("F") else { continue }
        var v = 0.0
        var type = [CChar](repeating: 0, count: 5)
        if lanes_smc_read_number(key, &v, &type) == 1 {
            print(String(format: "  SMC  %@ (%@) %10.3f", key as NSString, String(cString: type) as NSString, v))
        }
    }
    exit(0)
}

print("IOReport init:", lanes_power_init() == 1 ? "ok" : "FAILED")
print("SMC open:     ", lanes_smc_open() == 1 ? "ok" : "FAILED")
print()

let smcKeys = ["PSTR", "PDTR", "PPBR", "PCPC", "PCPG", "PC0C", "PCTR", "PHPC", "PDCR", "PMVC", "PZ0E"]

for round in 1...limit {
    Thread.sleep(forTimeInterval: 1.0)
    print("--- sample \(round)")

    var channels = [lanes_power_channel](repeating: lanes_power_channel(), count: 128)
    let n = Int(lanes_power_read(&channels, 128))
    if n < 0 { print("IOReport: no data") }
    for i in 0..<max(n, 0) {
        let name = withUnsafePointer(to: &channels[i].name) {
            $0.withMemoryRebound(to: CChar.self, capacity: 64) { String(cString: $0) }
        }
        print(String(format: "  IOReport  %-28@ %8.3f W", name as NSString, channels[i].watts))
    }

    for key in smcKeys {
        var v = 0.0
        if lanes_smc_read_float(key, &v) == 1 {
            print(String(format: "  SMC       %-28@ %8.3f", key as NSString, v))
        }
    }
    fflush(stdout)
}
