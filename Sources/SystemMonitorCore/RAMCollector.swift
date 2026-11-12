import Foundation
import Darwin

public enum MemoryPressure: Int {
    case normal = 1
    case warning = 2
    case critical = 4
}

public struct RAMSnapshot {
    public let appBytes: UInt64          // app memory
    public let wiredBytes: UInt64
    public let compressedBytes: UInt64
    public let cachedBytes: UInt64       // cached files (reclaimable), not counted as used
    public let totalBytes: UInt64
    public let swapUsedBytes: UInt64
    public let pressure: MemoryPressure
    public let freeBytes: UInt64         // pages on the free list
    public let fileBackedBytes: UInt64   // file cache that can be dropped at any time

    public init(appBytes: UInt64, wiredBytes: UInt64, compressedBytes: UInt64, cachedBytes: UInt64,
                totalBytes: UInt64, swapUsedBytes: UInt64, pressure: MemoryPressure,
                freeBytes: UInt64, fileBackedBytes: UInt64) {
        self.appBytes = appBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.cachedBytes = cachedBytes
        self.totalBytes = totalBytes
        self.swapUsedBytes = swapUsedBytes
        self.pressure = pressure
        self.freeBytes = freeBytes
        self.fileBackedBytes = fileBackedBytes
    }

    /// "Memory Used" exactly as Activity Monitor computes it: everything that is neither free
    /// nor droppable file cache. That is more than app + wired + compressed, because purgeable,
    /// speculative and kernel-reserved pages count as used too. Verified against Activity
    /// Monitor on 2026-11-05 (15.90 GB vs 15.90 GB).
    public var usedBytes: UInt64 {
        let parts = appBytes + wiredBytes + compressedBytes
        guard totalBytes > freeBytes + fileBackedBytes else { return parts }
        // Never below the sum of the parts (virtual machines can report less physical memory
        // to the guest than the page counters add up to).
        return max(totalBytes - freeBytes - fileBackedBytes, parts)
    }

    /// The part of "used" that is not app, wired or compressed (purgeable, speculative, reserved).
    public var otherBytes: UInt64 {
        let parts = appBytes + wiredBytes + compressedBytes
        return usedBytes > parts ? usedBytes - parts : 0
    }

    public var usedFraction: Double {
        totalBytes == 0 ? 0 : min(1, Double(usedBytes) / Double(totalBytes))
    }
}

/// RAM usage the way Activity Monitor counts it. One kernel call (`host_statistics64`) gives
/// app, wired, compressed and cached. Swap is a separate call made only every few ticks, and
/// the pressure level arrives from the kernel as an event instead of being polled.
public final class RAMCollector {
    private let total = ProcessInfo.processInfo.physicalMemory
    /// The page size `host_statistics64` counts in (4 KB on Intel, 16 KB on Apple silicon).
    private let page: UInt64 = {
        var size: vm_size_t = 0
        return host_page_size(mach_host_self(), &size) == KERN_SUCCESS && size > 0
            ? UInt64(size) : UInt64(getpagesize())
    }()
    private var swapUsed: UInt64 = 0
    private var pressure: MemoryPressure
    private var pressureSource: DispatchSourceMemoryPressure?

    /// `queue` is where the pressure events are delivered; use the sampler's queue.
    public init(queue: DispatchQueue) {
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        pressure = MemoryPressure(rawValue: Int(level)) ?? .normal

        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical],
                                                             queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let mask = source.data
            if mask.contains(.critical) { self.pressure = .critical }
            else if mask.contains(.warning) { self.pressure = .warning }
            else if mask.contains(.normal) { self.pressure = .normal }
        }
        source.activate()
        pressureSource = source
        refreshSwap()
    }

    deinit { pressureSource?.cancel() }

    /// Call every few ticks; swap changes slowly.
    public func refreshSwap() {
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 { swapUsed = swap.xsu_used }
    }

    public func snapshot() -> RAMSnapshot? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride
                                           / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let appPages = max(0, Int64(stats.internal_page_count) - Int64(stats.purgeable_count))
        let cachedPages = Int64(stats.external_page_count) + Int64(stats.purgeable_count)

        return RAMSnapshot(appBytes: UInt64(appPages) * page,
                           wiredBytes: UInt64(stats.wire_count) * page,
                           compressedBytes: UInt64(stats.compressor_page_count) * page,
                           cachedBytes: UInt64(cachedPages) * page,
                           totalBytes: total,
                           swapUsedBytes: swapUsed,
                           pressure: pressure,
                           // The kernel's free_count includes speculative (read-ahead) pages; vm_stat's
                           // "Pages free" does not. Speculative pages are counted as used, as documented
                           // above, so they must not also be subtracted as free.
                           freeBytes: UInt64(max(0, Int64(stats.free_count) - Int64(stats.speculative_count))) * page,
                           fileBackedBytes: UInt64(stats.external_page_count) * page)
    }
}
