import Foundation
import IOKit

/// GPU utilization (0...1) from IOKit's accelerator statistics. The accelerator entry is
/// looked up once; each tick reads a single property from it.
/// The key is undocumented and may change between macOS versions, so nil is normal and the
/// UI just hides the row.
public struct GPUDetails: Equatable {
    public let device: Double
    public let renderer: Double
    public let tiler: Double

    public init(device: Double, renderer: Double, tiler: Double) {
        self.device = device
        self.renderer = renderer
        self.tiler = tiler
    }
}

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

    public func utilization() -> Double? {
        var best: Double?
        for entry in entries {
            guard let perf = IORegistryEntryCreateCFProperty(
                    entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any],
                  let percent = (perf["Device Utilization %"] as? NSNumber)?.doubleValue
            else { continue }
            best = max(best ?? 0, min(1, percent / 100))
        }
        return best
    }

    /// Device, Renderer and Tiler load (0...1). macOS reports no per-GPU-core numbers without admin
    /// rights, so these three are all the detail there is.
    public func details() -> GPUDetails? {
        for entry in entries {
            guard let perf = IORegistryEntryCreateCFProperty(
                    entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any],
                  let device = (perf["Device Utilization %"] as? NSNumber)?.doubleValue
            else { continue }
            func fraction(_ key: String) -> Double { min(1, max(0, ((perf[key] as? NSNumber)?.doubleValue ?? 0) / 100)) }
            return GPUDetails(device: min(1, device / 100), renderer: fraction("Renderer Utilization %"),
                              tiler: fraction("Tiler Utilization %"))
        }
        return nil
    }
}
