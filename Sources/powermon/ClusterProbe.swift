import Foundation
import CPower
import SystemMonitorCore

/// Finds which SMC temperature keys belong to which core cluster by loading chosen clusters and
/// watching which keys rise. Background-QoS threads run on the Efficiency cores; user-interactive
/// threads go to the Super/Performance cores first. Per-core load is printed so thread placement is
/// checked, not assumed. Usage: powermon --cluster-probe   (about 80 seconds, uses the whole CPU)
func runClusterProbe(efficiencyOnly: Bool = false) {
    guard lanes_smc_open() == 1 else { print("SMC unavailable"); return }

    let keys = SMCKeys.all().filter { key in
        var v = 0.0
        return key.hasPrefix("T") && lanes_smc_read_float(key, &v) == 1 && v > 5 && v < 130
    }
    let topology = CPUTopology.detect()
    print("keys: \(keys.count), clusters: \(topology.clusters.map { "\($0.name)=\($0.cpus)" })")

    let cpu = CPUCollector()
    _ = cpu.perCoreUsage()

    struct Phase {
        let name: String
        let threads: Int
        let qos: QualityOfService
    }
    let phases = efficiencyOnly
        ? [Phase(name: "E6 bg", threads: 6, qos: .background)]
        : [Phase(name: "E6 bg", threads: 6, qos: .background),
           Phase(name: "S2 int", threads: 2, qos: .userInteractive),
           Phase(name: "P4 int", threads: 4, qos: .userInteractive),
           Phase(name: "ALL12", threads: 12, qos: .userInteractive)]
    // The Efficiency-only run is long and starts from a cool, idle Mac so heat from other clusters
    // does not hide its small rise.
    let settle = efficiencyOnly ? 40.0 : 7.0
    let loadSeconds = efficiencyOnly ? 45.0 : 12.5

    func sample() -> [Double] {
        keys.map { key in
            var v = 0.0
            return lanes_smc_read_float(key, &v) == 1 ? v : 0
        }
    }

    /// Mean of each key over `count` samples taken 0.5 s apart; also mean per-core load.
    func window(seconds: Double) -> (temps: [Double], cores: [Double]) {
        var sums = [Double](repeating: 0, count: keys.count)
        var coreSums = [Double](repeating: 0, count: topology.coreCount)
        var n = 0.0
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            Thread.sleep(forTimeInterval: 0.5)
            let t = sample()
            for i in t.indices { sums[i] += t[i] }
            if let c = cpu.perCoreUsage() { for i in c.indices where i < coreSums.count { coreSums[i] += c[i] } }
            n += 1
        }
        return (sums.map { $0 / n }, coreSums.map { $0 / n })
    }

    func busy(threads: Int, qos: QualityOfService, seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        for _ in 0..<threads {
            let t = Thread {
                var x = 1.0
                while Date() < deadline {
                    for _ in 0..<200_000 { x = x * 1.0000001 + 0.0000001 }
                }
                if x < 0 { print(x) }
            }
            t.qualityOfService = qos
            t.start()
        }
    }

    func clusterLoad(_ cores: [Double]) -> String {
        topology.clusters.map { c in
            let mean = c.cpus.map { cores[$0] }.reduce(0, +) / Double(max(c.cpus.count, 1))
            return String(format: "%@ %2.0f%%", c.name as NSString, mean * 100)
        }.joined(separator: "  ")
    }

    var rows: [[Double]] = []   // per phase: delta per key
    for phase in phases {
        print("--- idle \(Int(settle) + 3) s"); fflush(stdout)
        Thread.sleep(forTimeInterval: settle)
        let base = window(seconds: 3)
        print("--- \(phase.name): \(phase.threads) threads"); fflush(stdout)
        busy(threads: phase.threads, qos: phase.qos, seconds: loadSeconds + 5)
        Thread.sleep(forTimeInterval: loadSeconds - 5)
        let loaded = window(seconds: 5)
        print("    placement: \(clusterLoad(loaded.cores))"); fflush(stdout)
        rows.append(zip(loaded.temps, base.temps).map { $0 - $1 })
        Thread.sleep(forTimeInterval: 1)
    }

    print("\nkey    " + phases.map { $0.name.padding(toLength: 8, withPad: " ", startingAt: 0) }.joined())
    for (i, key) in keys.enumerated() {
        let deltas = rows.map { $0[i] }
        if deltas.allSatisfy({ abs($0) < 0.4 }) { continue }   // flat sensors are not interesting
        print(key + "   " + deltas.map { String(format: "%+5.1f   ", $0) }.joined())
    }
}
