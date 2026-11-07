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

/// Temperatures and fan speed without admin rights: SMC for CPU, GPU and fans, IOHID for the SSD.
/// All of these are Apple-internal and differ per chip, so any value can be nil on a given Mac.
/// Sensor groups were found by running `powermon --temps` idle and under load on an M6:
/// `Tp*` rise with CPU load (cores), `Tg*` are the GPU, `NAND` is the flash.
public final class ThermalCollector {
    private let smcOK: Bool
    private var cpuKeys: [String] = []
    private var gpuKeys: [String] = []
    private var fanCount = 0
    private var sensors = [lanes_temp_sensor](repeating: lanes_temp_sensor(), count: 64)

    public init() {
        smcOK = lanes_smc_open() == 1
        guard smcOK else { return }
        // Key list is fixed for the life of the machine: walk it once, keep only the working sensors.
        let total = Int(lanes_smc_key_count())
        for i in 0..<total {
            var raw = [CChar](repeating: 0, count: 5)
            guard lanes_smc_key_at(Int32(i), &raw) == 1 else { continue }
            let key = String(cString: raw)
            let isCPU = key.hasPrefix("Tp"), isGPU = key.hasPrefix("Tg")
            guard isCPU || isGPU else { continue }
            var v = 0.0
            // Skip keys that read 0 (unpopulated) or are not a plausible temperature.
            guard lanes_smc_read_float(key, &v) == 1, v > 5, v < 130 else { continue }
            if isCPU { cpuKeys.append(key) } else { gpuKeys.append(key) }
        }
        var n = 0.0
        if lanes_smc_read_number("FNum", &n, nil) == 1 { fanCount = Int(n) }
    }

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
