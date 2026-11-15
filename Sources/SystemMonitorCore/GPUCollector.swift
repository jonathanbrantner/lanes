import Foundation
import IOKit

/// Device, Renderer and Tiler load (0...1). macOS reports no per-GPU-core numbers without admin
/// rights, so these three are all the detail there is.
public struct GPUDetails: Equatable {
    public let device: Double
    public let renderer: Double
    public let tiler: Double
    /// Memory the GPU is using, in bytes (shared with the CPU on Apple Silicon). nil if not reported.
    public let memoryBytes: Double?

    public init(device: Double, renderer: Double, tiler: Double, memoryBytes: Double? = nil) {
        self.device = device
        self.renderer = renderer
        self.tiler = tiler
        self.memoryBytes = memoryBytes
    }
}

/// GPU utilization (0...1) from IOKit's accelerator statistics. The accelerator entry is
/// looked up once; each tick reads a single property from it.
/// The key is undocumented and may change between macOS versions, so nil is normal and the
/// UI just hides the row.
public final class GPUCollector {
    private var entries: [io_object_t] = []

    public init() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"),
                                           &iterator) == KERN_SUCCESS else { return }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            entries.append(entry)   // keep the reference; released in deinit
        }
        IOObjectRelease(iterator)
    }

    deinit { entries.forEach { IOObjectRelease($0) } }

    /// Number of GPU cores (`gpu-core-count` on the accelerator entry). Read once; nil if the
    /// Mac does not report it.
    public lazy var coreCount: Int? = {
        for entry in entries {
            if let n = IORegistryEntryCreateCFProperty(entry, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber, n.intValue > 0 { return n.intValue }
        }
        return nil
    }()

    private func performanceStats(_ entry: io_object_t) -> [String: Any]? {
        IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any]
    }

    private static func fraction(_ stats: [String: Any], _ key: String) -> Double? {
        (stats[key] as? NSNumber).map { min(1, max(0, $0.doubleValue / 100)) }
    }

    public func utilization() -> Double? {
        var best: Double?
        for entry in entries {
            guard let stats = performanceStats(entry), let device = Self.fraction(stats, "Device Utilization %")
            else { continue }
            best = max(best ?? 0, device)
        }
        return best
    }

    /// Reads the three loads in one registry read; use instead of `utilization()` when the detail
    /// is shown, so the statistics are not fetched twice per tick.
    public func details() -> GPUDetails? {
        for entry in entries {
            guard let stats = performanceStats(entry), let device = Self.fraction(stats, "Device Utilization %")
            else { continue }
            return GPUDetails(device: device,
                              renderer: Self.fraction(stats, "Renderer Utilization %") ?? 0,
                              tiler: Self.fraction(stats, "Tiler Utilization %") ?? 0,
                              memoryBytes: (stats["In use system memory"] as? NSNumber)?.doubleValue)
        }
        return nil
    }
}
