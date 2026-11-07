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
