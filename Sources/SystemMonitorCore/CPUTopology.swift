import Foundation
import IOKit

public enum ClusterKind {
    case superCore, performance, efficiency

    /// Maps macOS's own core class name ("Super", "Performance", "Efficiency").
    static func from(name: String) -> ClusterKind {
        switch name {
        case "Super": .superCore
        case "Efficiency": .efficiency
        default: .performance
        }
    }
}

public struct CPUCluster: Equatable {
    public let kind: ClusterKind
    public let name: String
    /// Logical CPU numbers (the order `host_processor_info` reports cores in).
    public let cpus: [Int]
}

/// Which logical CPU is which kind of core. Read once: it never changes while the Mac is on.
/// Source: the device tree's `cluster-type` per `logical-cpu-id` ("E", "P", and "M" on chips with
/// three core classes) ranked P, M, E, and named by `hw.perflevelN.name`.
public struct CPUTopology: Equatable {
    /// Highest performance class first.
    public let clusters: [CPUCluster]

    public var coreCount: Int { clusters.reduce(0) { $0 + $1.cpus.count } }

    public init(clusters: [CPUCluster]) { self.clusters = clusters }

    /// Pure and testable: `types[i]` is the cluster-type of logical CPU i, `names` the perflevel
    /// names from highest to lowest performance.
    public static func build(types: [String], names: [String]) -> CPUTopology {
        let rankOrder = ["P", "M", "E"]
        let present = rankOrder.filter { types.contains($0) }
        // Unknown cluster types go last as one extra class.
        let unknown = Set(types).subtracting(rankOrder).sorted()
        let classes = present + unknown

        var clusters: [CPUCluster] = []
        for (rank, type) in classes.enumerated() {
            let cpus = types.enumerated().filter { $0.element == type }.map(\.offset)
            let name: String
            if names.count == classes.count { name = names[rank] }
            else { name = type == "E" ? "Efficiency" : "Performance" }
            clusters.append(CPUCluster(kind: .from(name: name), name: name, cpus: cpus))
        }
        return CPUTopology(clusters: clusters)
    }

    public static func detect() -> CPUTopology {
        let types = readClusterTypes()
        let levels = Sysctl.int("hw.nperflevels") ?? 0
        var names: [String] = []
        for i in 0..<levels {
            if let n = Sysctl.string("hw.perflevel\(i).name") { names.append(n) }
        }
        if types.isEmpty {
            // No device tree info: one class with every core.
            let n = Sysctl.int("hw.ncpu") ?? 0
            return CPUTopology(clusters: [CPUCluster(kind: .performance, name: "Cores", cpus: Array(0..<n))])
        }
        return build(types: types, names: names)
    }

    private static func readClusterTypes() -> [String] {
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard cpus != 0 else { return [] }
        defer { IOObjectRelease(cpus) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var byID: [Int: String] = [:]
        while case let child = IOIteratorNext(iterator), child != 0 {
            defer { IOObjectRelease(child) }
            guard let idRef = IORegistryEntryCreateCFProperty(child, "logical-cpu-id" as CFString, kCFAllocatorDefault, 0),
                  let id = (idRef.takeRetainedValue() as? NSNumber)?.intValue,
                  let typeRef = IORegistryEntryCreateCFProperty(child, "cluster-type" as CFString, kCFAllocatorDefault, 0),
                  let data = typeRef.takeRetainedValue() as? Data
            else { continue }
            let type = String(decoding: data.filter { $0 != 0 }, as: UTF8.self)
            byID[id] = type
        }
        guard !byID.isEmpty, let maxID = byID.keys.max() else { return [] }
        return (0...maxID).map { byID[$0] ?? "?" }
    }
}
