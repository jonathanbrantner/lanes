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

/// Which readings to take. Anything not asked for costs nothing.
public struct ThermalWanted: OptionSet {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let cpu = ThermalWanted(rawValue: 1)
    public static let gpu = ThermalWanted(rawValue: 2)
    public static let ram = ThermalWanted(rawValue: 4)
    public static let ssd = ThermalWanted(rawValue: 8)
    public static let fan = ThermalWanted(rawValue: 16)
    public static let clusters = ThermalWanted(rawValue: 32)
    public static let gpuSensors = ThermalWanted(rawValue: 64)
}

public struct ThermalSnapshot: Equatable {
    /// Average of the CPU core sensors, in °C. nil if this Mac doesn't expose them.
    public let cpuC: Double?
    /// Average of the GPU sensors, in °C.
    public let gpuC: Double?
    /// Memory temperature, in °C. Only on chips that expose a memory sensor (M1 and M4 do; M6 does not).
    public let ramC: Double?
    /// Flash storage (NAND) temperature, in °C.
    public let ssdC: Double?
    public let fans: [FanReading]
    /// Temperature per core class (Super / Performance / Efficiency). Only classes whose sensors
    /// were checked on a real Mac appear; Apple gives no per-core temperatures.
    public let clusterC: [ClusterKind: Double]
    /// The GPU's individual sensors in a fixed order. They are sensors, not cores.
    public let gpuSensorsC: [Double]

    /// Average of whichever of CPU, GPU, memory and SSD temperatures were read. nil if fewer than two.
    public var averageC: Double? {
        let parts = [cpuC, gpuC, ramC, ssdC].compactMap { $0 }
        return parts.count >= 2 ? parts.reduce(0, +) / Double(parts.count) : nil
    }

    public init(cpuC: Double?, gpuC: Double?, ramC: Double? = nil, ssdC: Double?, fans: [FanReading],
                clusterC: [ClusterKind: Double] = [:], gpuSensorsC: [Double] = []) {
        self.clusterC = clusterC
        self.gpuSensorsC = gpuSensorsC
        self.cpuC = cpuC
        self.gpuC = gpuC
        self.ramC = ramC
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

    /// Short name for menus.
    public var shortTitle: String {
        self == .other ? "Newer / other" : rawValue.uppercased()
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

    /// SMC keys per core class, for the per-cluster temperatures. An empty result means "no verified
    /// table for this chip": the cluster rows are then hidden instead of guessed.
    /// - M6: checked on an M6 Mac mini (2 Super, 4 Performance, 6 Efficiency) by loading one class at a
    ///   time (`powermon --cluster-probe`): the Super keys saturate with only the 2 Super cores busy,
    ///   the Performance keys jump when the Performance cores join, the Efficiency keys lead in an
    ///   Efficiency-only run.
    /// - M1 to M4: the Efficiency/Performance split from the open-source Stats app's sensor list,
    ///   not checked on those chips.
    var clusterKeys: [ClusterKind: [String]] {
        switch self {
        case .m1:
            return [.efficiency: ["Tp09", "Tp0T"],
                    .performance: ["Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"]]
        case .m2:
            return [.efficiency: ["Tp1h", "Tp1t", "Tp1p", "Tp1l"],
                    .performance: ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"]]
        case .m3:
            return [.efficiency: ["Te05", "Te0L", "Te0P", "Te0S"],
                    .performance: ["Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E",
                                   "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"]]
        case .m4:
            return [.efficiency: ["Te05", "Te0S", "Te09", "Te0H"],
                    .performance: ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"]]
        case .m6:
            return [.superCore: ["Tp0g", "Tp0j", "Tp07", "Tp09"],
                    .performance: ["Tp0m", "Tp0L", "Tp0I", "Tp0d", "Tp0E", "Tp0G"],
                    .efficiency: ["Te07", "Te08", "Te09"]]
        case .m5, .other:
            return [:]
        }
    }

    /// (CPU keys, GPU keys, memory keys). Keys a given Mac doesn't have are dropped when the collector starts.
    var keys: (cpu: [String], gpu: [String], ram: [String]) {
        switch self {
        case .m1:
            return (["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"],
                    ["Tg05", "Tg0D", "Tg0L", "Tg0T"], ["Tm02", "Tm06", "Tm08", "Tm09"])
        case .m2:
            return (["Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"],
                    ["Tg0f", "Tg0j"], [])
        case .m3:
            return (["Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E",
                     "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"],
                    ["Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"], [])
        case .m4:
            return (["Te05", "Te0S", "Te09", "Te0H", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"],
                    ["Tg0G", "Tg0H", "Tg1U", "Tg1k", "Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k"], ["Tm0p", "Tm1p", "Tm2p"])
        case .m5:
            return (["Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K", "Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a",
                     "Tp0d", "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y"],
                    ["Tg0U", "Tg0X", "Tg0d", "Tg0g", "Tg0j", "Tg1Y", "Tg1c", "Tg1g"], [])
        case .m6:
            return (["Tp0j", "Tp0g", "Tp09", "Tp07", "Tp0m", "Tp0L", "Tp0I", "Tp0d", "Tp0E", "Tp0G", "Tp0b", "Tp05",
                     "Te07", "Te08", "Te09", "Te0c", "Te0h", "Te0i"],
                    ["Tg1e", "Tg0d", "Tg0c", "Tg0b", "Tg1c", "Tg1d", "Tg07", "Tg1f", "Tg09", "Tg0a", "Tg1g", "Tg1h"], [])
        case .other:
            return ([], [], [])   // filled by scanning, see ThermalCollector
        }
    }
}

/// Temperatures and fan speed without admin rights: SMC for CPU, GPU, memory and fans, IOHID for the SSD.
/// All of these are Apple-internal and differ per chip, so any value can be nil on a given Mac.
/// Needs the chip generation to know which SMC keys to read (see `ChipFamily`).
/// Cheap by design: keys are checked once at start, the SSD sensor and the fan limits are looked up
/// once, and `snapshot(wanted:)` only touches the sensors that are actually on screen.
public final class ThermalCollector {
    public let chip: ChipFamily
    private let smcOK: Bool
    private var cpuKeys: [String] = []
    private var gpuKeys: [String] = []
    private var ramKeys: [String] = []
    private var fanKeys: [(actual: String, lo: Double, hi: Double)] = []
    private var clusterKeys: [ClusterKind: [String]] = [:]

    public init(chip: ChipFamily) {
        self.chip = chip
        smcOK = lanes_smc_open() == 1
        guard smcOK else { return }

        if chip == .other {
            // Unknown chip: walk the SMC key list once and keep every working Tp/Te (CPU), Tg (GPU), Tm (memory) key.
            let total = Int(lanes_smc_key_count())
            for i in 0..<total {
                var raw = [CChar](repeating: 0, count: 5)
                guard lanes_smc_key_at(Int32(i), &raw) == 1 else { continue }
                let key = String(cString: raw)
                if key.hasPrefix("Tp") || key.hasPrefix("Te") { cpuKeys.append(key) }
                else if key.hasPrefix("Tg") { gpuKeys.append(key) }
                else if key.hasPrefix("Tm") { ramKeys.append(key) }
            }
        } else {
            (cpuKeys, gpuKeys, ramKeys) = chip.keys
        }
        // Keep only keys that really read as a temperature on this Mac (a wrong chip choice leaves none).
        cpuKeys = cpuKeys.filter(Self.reads)
        gpuKeys = gpuKeys.filter(Self.reads)
        ramKeys = ramKeys.filter(Self.reads)
        for (kind, keys) in chip.clusterKeys {
            let working = keys.filter(Self.reads)
            if !working.isEmpty { clusterKeys[kind] = working }
        }

        // Fans: the speed limits never change, so read them once.
        var n = 0.0
        if lanes_smc_read_number("FNum", &n, nil) == 1 {
            for i in 0..<min(Int(n), 4) {
                var lo = 0.0, hi = 0.0
                if lanes_smc_read_float("F\(i)Mn", &lo) == 1, lanes_smc_read_float("F\(i)Mx", &hi) == 1 {
                    fanKeys.append(("F\(i)Ac", lo, hi))
                }
            }
        }
    }

    private static func reads(_ key: String) -> Bool {
        var v = 0.0
        return lanes_smc_read_float(key, &v) == 1 && Self.plausible(v)
    }

    private static func plausible(_ c: Double) -> Bool { c > 5 && c < 130 }

    /// Core classes that have a temperature on this Mac.
    public var clusterKinds: [ClusterKind] { clusterKeys.keys.sorted() }

    /// True if the chosen chip's keys matched sensors on this Mac.
    public var foundCPUSensors: Bool { !cpuKeys.isEmpty }

    public func snapshot(wanted: ThermalWanted = [.cpu, .gpu, .ram, .ssd, .fan]) -> ThermalSnapshot? {
        let cpu = wanted.contains(.cpu) ? average(cpuKeys) : nil
        let gpu = wanted.contains(.gpu) ? average(gpuKeys) : nil
        let ram = wanted.contains(.ram) ? average(ramKeys) : nil

        var ssd: Double?
        if wanted.contains(.ssd) {
            var c = 0.0
            if lanes_hid_named_temp("NAND", &c) == 1, Self.plausible(c) { ssd = c }
        }

        var fans: [FanReading] = []
        if wanted.contains(.fan) {
            for f in fanKeys {
                var rpm = 0.0
                if lanes_smc_read_float(f.actual, &rpm) == 1 {
                    fans.append(FanReading(rpm: rpm, minRPM: f.lo, maxRPM: f.hi))
                }
            }
        }

        var clusters: [ClusterKind: Double] = [:]
        if wanted.contains(.clusters) {
            for (kind, keys) in clusterKeys { if let c = average(keys) { clusters[kind] = c } }
        }
        var gpuSensors: [Double] = []
        if wanted.contains(.gpuSensors) {
            for key in gpuKeys {
                var v = 0.0
                if lanes_smc_read_float(key, &v) == 1, Self.plausible(v) { gpuSensors.append(v) }
            }
        }

        if cpu == nil && gpu == nil && ram == nil && ssd == nil && fans.isEmpty
            && clusters.isEmpty && gpuSensors.isEmpty { return nil }
        return ThermalSnapshot(cpuC: cpu, gpuC: gpu, ramC: ram, ssdC: ssd, fans: fans,
                               clusterC: clusters, gpuSensorsC: gpuSensors)
    }

    private func average(_ keys: [String]) -> Double? {
        var sum = 0.0, count = 0.0
        for key in keys {
            var v = 0.0
            if lanes_smc_read_float(key, &v) == 1, Self.plausible(v) { sum += v; count += 1 }
        }
        return count > 0 ? sum / count : nil
    }
}
