import Foundation
import Darwin

/// Overall CPU usage (0...1) since the previous call. First call returns nil.
/// Uses `host_statistics(HOST_CPU_LOAD_INFO)`: one small struct, no per-core buffer to allocate.
public final class CPUCollector {
    private var previous: (busy: UInt64, total: UInt64)?
    private var previousCores: [(busy: UInt64, total: UInt64)] = []

    public init() {}

    public func usage() -> Double? {
        var load = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride
                                           / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &load) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let user = UInt64(load.cpu_ticks.0), system = UInt64(load.cpu_ticks.1)
        let idle = UInt64(load.cpu_ticks.2), nice = UInt64(load.cpu_ticks.3)
        let busy = user + system + nice
        let total = busy + idle

        defer { previous = (busy, total) }
        guard let previous, total > previous.total else { return nil }
        return Double(busy &- previous.busy) / Double(total &- previous.total)
    }

    /// Forget the previous per-core ticks, so the next reading starts fresh instead of averaging over
    /// however long the core view was closed.
    public func resetPerCore() { previousCores = [] }

    /// Load (0...1) of every logical core since the previous call, in `host_processor_info` order
    /// (logical CPU 0, 1, 2 ...). First call returns nil. Public API, no admin rights; the buffer the
    /// kernel hands back is freed before returning. Only called while the core view is open.
    public func perCoreUsage() -> [Double]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }

        let states = Int(CPU_STATE_MAX)
        var now: [(busy: UInt64, total: UInt64)] = []
        for core in 0..<Int(cpuCount) {
            func ticks(_ state: Int32) -> UInt64 { UInt64(UInt32(bitPattern: info[core * states + Int(state)])) }
            let busy = ticks(CPU_STATE_USER) + ticks(CPU_STATE_SYSTEM) + ticks(CPU_STATE_NICE)
            now.append((busy, busy + ticks(CPU_STATE_IDLE)))
        }
        defer { previousCores = now }
        guard previousCores.count == now.count else { return nil }

        return zip(now, previousCores).map { cur, prev in
            let total = cur.total &- prev.total
            guard total > 0 else { return 0 }
            return min(1, Double(cur.busy &- prev.busy) / Double(total))
        }
    }
}
