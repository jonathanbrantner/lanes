import Foundation
import CPower

public struct PowerSnapshot: Equatable {
    /// Whole-system power draw in watts (SMC sensor). nil if this Mac doesn't expose it.
    public let systemWatts: Double?
    /// GPU power in watts (IOReport energy counters). nil if not exposed.
    public let gpuWatts: Double?
    /// Energy used by the PCIe / Thunderbolt port controllers (IOReport). This is the controller, not
    /// what a device plugged into a port draws, which macOS does not report. nil if not exposed.
    public let portsWatts: Double?

    public init(systemWatts: Double?, gpuWatts: Double?, portsWatts: Double? = nil) {
        self.systemWatts = systemWatts
        self.gpuWatts = gpuWatts
        self.portsWatts = portsWatts
    }
}

/// Power draw without admin rights: SMC for the system total, IOReport for the GPU.
/// Both are Apple-internal interfaces, so any value can be nil on a given Mac or macOS version.
/// CPU, DRAM and Neural Engine power are not shown because the M6 doesn't expose those channels.
public final class PowerCollector {
    private let ioReportOK: Bool
    private let smcOK: Bool
    /// The SMC key that worked on this Mac, found on the first read and reused after.
    private var systemKey: String?
    private var channels = [lanes_power_channel](repeating: lanes_power_channel(), count: 64)

    public init() {
        ioReportOK = lanes_power_init() == 1
        smcOK = lanes_smc_open() == 1
    }

    public func snapshot() -> PowerSnapshot? {
        var system: Double?
        if smcOK {
            for key in systemKey.map({ [$0] }) ?? ["PSTR", "PDTR"] {
                var value = 0.0
                if lanes_smc_read_float(key, &value) == 1, value > 0 {
                    system = value
                    systemKey = key
                    break
                }
            }
        }

        var gpu: Double?
        var portsFromPorts: Double?
        var portsFromControllers: Double?
        if ioReportOK {
            let count = Int(lanes_power_read(&channels, Int32(channels.count)))
            for i in 0..<max(count, 0) {
                let name = withUnsafePointer(to: &channels[i].name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: 64) { String(cString: $0) }
                }
                if name == "GPU Energy" { gpu = channels[i].watts }
                // "PCIe Port 0 Energy" and the controllers behind them ("apciec0 Energy"): use the ports,
                // and only fall back to the controllers so nothing is counted twice.
                if name.hasPrefix("PCIe Port") { portsFromPorts = (portsFromPorts ?? 0) + channels[i].watts }
                if name.hasPrefix("apciec") { portsFromControllers = (portsFromControllers ?? 0) + channels[i].watts }
            }
        }

        let ports = portsFromPorts ?? portsFromControllers
        if system == nil && gpu == nil { return nil }
        return PowerSnapshot(systemWatts: system, gpuWatts: gpu, portsWatts: ports)
    }
}
