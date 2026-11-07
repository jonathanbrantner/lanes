import Foundation
import CPower

public struct FanReading: Equatable {
    public let rpm: Double
    public let minRPM: Double
    public let maxRPM: Double

    public init(rpm: Double, minRPM: Double, maxRPM: Double) {
        self.rpm = rpm
        self.minRPM = minRPM
        self.maxRPM = maxRPM
    }

    /// 0...1 between the fan's minimum and maximum speed.
    public var fraction: Double {
        guard maxRPM > minRPM else { return 0 }
        return min(max((rpm - minRPM) / (maxRPM - minRPM), 0), 1)
    }
}

public struct ThermalSnapshot: Equatable {
    /// Average of the CPU core sensors, in °C. nil if this Mac doesn't expose them.
    public let cpuC: Double?
    /// Average of the GPU sensors, in °C.
    public let gpuC: Double?
    /// Flash storage (NAND) temperature, in °C.
    public let ssdC: Double?
    public let fans: [FanReading]

    public init(cpuC: Double?, gpuC: Double?, ssdC: Double?, fans: [FanReading]) {
        self.cpuC = cpuC
        self.gpuC = gpuC
        self.ssdC = ssdC
        self.fans = fans
    }
}

/// Apple Silicon generation. Each one names its temperature sensors differently, so Lanes keeps a
/// key table per generation (from the open-source Stats app's sensor list, checked on an M6).
/// `.other` reads every Tp/Te/Tg sensor it finds, for chips Lanes doesn't have a table for yet.
public enum ChipFamily: String, CaseIterable, Identifiable {
    case m1, m2, m3, m4, m5, m6, other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .m1: "M1 (Pro, Max, Ultra)"
        case .m2: "M2 (Pro, Max, Ultra)"
        case .m3: "M3 (Pro, Max, Ultra)"
        case .m4: "M4 (Pro, Max)"
        case .m5: "M5 (Pro, Max)"
        case .m6: "M6 (Pro, Max)"
        case .other: "Other / newer (scan)"
        }
    }

    /// The chip this Mac has, from its CPU name ("Apple M4 Pro"). Newer or unparseable names give `.other`.
    public static func detect() -> ChipFamily {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        return parse(String(cString: buffer))
    }

    static func parse(_ brand: String) -> ChipFamily {
        guard let range = brand.range(of: #"Apple M(\d+)"#, options: .regularExpression) else { return .other }
        switch brand[range].dropFirst("Apple M".count) {
        case "1": return .m1
        case "2": return .m2
        case "3": return .m3
        case "4": return .m4
        case "5": return .m5
        case "6": return .m6
        default: return .other
        }
    }

    /// (CPU keys, GPU keys). Keys a given Mac doesn't have are dropped when the collector starts.
    var keys: (cpu: [String], gpu: [String]) {
        switch self {
        case .m1:
            return (["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"],
                    ["Tg05", "Tg0D", "Tg0L", "Tg0T"])
        case .m2:
            return (["Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"],
                    ["Tg0f", "Tg0j"])
        case .m3:
            return (["Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E",
                     "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"],
                    ["Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"])
        case .m4:
            return (["Te05", "Te0S", "Te09", "Te0H", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"],
                    ["Tg0G", "Tg0H", "Tg1U", "Tg1k", "Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k"])
        case .m5:
            return (["Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K", "Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a",
                     "Tp0d", "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y"],
                    ["Tg0U", "Tg0X", "Tg0d", "Tg0g", "Tg0j", "Tg1Y", "Tg1c", "Tg1g"])
        case .m6:
            return (["Tp0j", "Tp0g", "Tp09", "Tp07", "Tp0m", "Tp0L", "Tp0I", "Tp0d", "Tp0E", "Tp0G", "Tp0b", "Tp05",
                     "Te07", "Te08", "Te09", "Te0c", "Te0h", "Te0i"],
                    ["Tg1e", "Tg0d", "Tg0c", "Tg0b", "Tg1c", "Tg1d", "Tg07", "Tg1f", "Tg09", "Tg0a", "Tg1g", "Tg1h"])
        case .other:
            return ([], [])   // filled by scanning, see ThermalCollector
        }
    }
}

/// Temperatures and fan speed without admin rights: SMC for CPU, GPU and fans, IOHID for the SSD.
/// All of these are Apple-internal and differ per chip, so any value can be nil on a given Mac.
/// Needs the chip generation to know which SMC keys to read (see `ChipFamily`).
public final class ThermalCollector {
    public let chip: ChipFamily
    private let smcOK: Bool
    private var cpuKeys: [String] = []
    private var gpuKeys: [String] = []
    private var fanCount = 0
    private var sensors = [lanes_temp_sensor](repeating: lanes_temp_sensor(), count: 64)

    public init(chip: ChipFamily) {
        self.chip = chip
        smcOK = lanes_smc_open() == 1
        guard smcOK else { return }

        if chip == .other {
            // Unknown chip: walk the SMC key list once and keep every working Tp/Te (CPU) and Tg (GPU) key.
            let total = Int(lanes_smc_key_count())
            for i in 0..<total {
                var raw = [CChar](repeating: 0, count: 5)
                guard lanes_smc_key_at(Int32(i), &raw) == 1 else { continue }
                let key = String(cString: raw)
                if key.hasPrefix("Tp") || key.hasPrefix("Te") { cpuKeys.append(key) }
                else if key.hasPrefix("Tg") { gpuKeys.append(key) }
            }
        } else {
            (cpuKeys, gpuKeys) = chip.keys
        }
        // Keep only keys that really read as a temperature on this Mac (a wrong chip choice leaves none).
        cpuKeys = cpuKeys.filter(Self.reads)
        gpuKeys = gpuKeys.filter(Self.reads)

        var n = 0.0
        if lanes_smc_read_number("FNum", &n, nil) == 1 { fanCount = Int(n) }
    }

    private static func reads(_ key: String) -> Bool {
        var v = 0.0
        return lanes_smc_read_float(key, &v) == 1 && v > 5 && v < 130
    }

    /// True if the chosen chip's keys matched sensors on this Mac.
    public var foundCPUSensors: Bool { !cpuKeys.isEmpty }

    public func snapshot() -> ThermalSnapshot? {
        let cpu = average(cpuKeys)
        let gpu = average(gpuKeys)

        var ssd: Double?
        let n = Int(lanes_hid_temps_read(&sensors, Int32(sensors.count)))
        for i in 0..<max(n, 0) {
            let name = withUnsafePointer(to: &sensors[i].name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 64) { String(cString: $0) }
            }
            let c = sensors[i].celsius
            if name.hasPrefix("NAND"), c > 0, c < 130 { ssd = max(ssd ?? 0, c) }
        }

        var fans: [FanReading] = []
        if smcOK {
            for i in 0..<min(fanCount, 4) {
                var rpm = 0.0, lo = 0.0, hi = 0.0
                if lanes_smc_read_float("F\(i)Ac", &rpm) == 1,
                   lanes_smc_read_float("F\(i)Mn", &lo) == 1,
                   lanes_smc_read_float("F\(i)Mx", &hi) == 1 {
                    fans.append(FanReading(rpm: rpm, minRPM: lo, maxRPM: hi))
                }
            }
        }

        if cpu == nil && gpu == nil && ssd == nil && fans.isEmpty { return nil }
        return ThermalSnapshot(cpuC: cpu, gpuC: gpu, ssdC: ssd, fans: fans)
    }

    private func average(_ keys: [String]) -> Double? {
        var sum = 0.0, count = 0.0
        for key in keys {
            var v = 0.0
            if lanes_smc_read_float(key, &v) == 1, v > 5, v < 130 { sum += v; count += 1 }
        }
        return count > 0 ? sum / count : nil
    }
}
