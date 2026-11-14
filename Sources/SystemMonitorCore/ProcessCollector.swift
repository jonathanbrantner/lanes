import Foundation
import Darwin

/// One running process: how busy it is and how much memory it holds.
public struct ProcessUsage: Equatable {
    public let pid: Int32
    public let name: String
    /// CPU use as Activity Monitor shows it: 100 = one full core, so it can exceed 100.
    public let cpuPercent: Double
    /// Memory footprint (what Activity Monitor's Memory column shows).
    public let footprintBytes: UInt64

    public init(pid: Int32, name: String, cpuPercent: Double, footprintBytes: UInt64) {
        self.pid = pid
        self.name = name
        self.cpuPercent = cpuPercent
        self.footprintBytes = footprintBytes
    }
}

/// Busiest processes via `libproc`, no admin rights. Processes of other users (and system daemons
/// running as root) are not readable and are skipped, like in Activity Monitor without sudo.
/// One sweep walks every readable process, so the app calls it only while the CPU or Memory page
/// is open, every few seconds.
public final class ProcessCollector {
    private var previous: [Int32: (cpuNs: UInt64, time: TimeInterval)] = [:]
    private let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    public init() {}

    /// Pure and testable: CPU percent from two cumulative CPU times (nanoseconds) and the seconds between.
    public static func cpuPercent(oldNs: UInt64, newNs: UInt64, seconds: Double) -> Double {
        guard seconds > 0, newNs >= oldNs else { return 0 }
        return Double(newNs - oldNs) / 1e9 / seconds * 100
    }

    /// Top `count` by CPU and by memory from one sweep. The first call has no CPU baseline yet.
    public func sample() -> [ProcessUsage] {
        let capacity = Int(proc_listallpids(nil, 0))
        guard capacity > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: capacity + 32)
        let bytes = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.stride))
        let found = Int(bytes) / MemoryLayout<Int32>.stride

        let now = ProcessInfo.processInfo.systemUptime
        var next: [Int32: (cpuNs: UInt64, time: TimeInterval)] = [:]
        var out: [ProcessUsage] = []
        for pid in pids.prefix(found) where pid > 0 {
            var task = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.stride)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, size) == size else { continue }
            let ticks = task.pti_total_user + task.pti_total_system
            let cpuNs = ticks * UInt64(timebase.numer) / UInt64(timebase.denom)
            next[pid] = (cpuNs, now)

            var rusage = rusage_info_v2()
            let ok = withUnsafeMutablePointer(to: &rusage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
            }
            let footprint = ok == 0 ? rusage.ri_phys_footprint : task.pti_resident_size

            var cpu = 0.0
            if let prev = previous[pid] { cpu = Self.cpuPercent(oldNs: prev.cpuNs, newNs: cpuNs, seconds: now - prev.time) }
            var nameBuffer = [CChar](repeating: 0, count: 64)
            proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
            let name = String(cString: nameBuffer)
            out.append(ProcessUsage(pid: pid, name: name.isEmpty ? "pid \(pid)" : name,
                                    cpuPercent: cpu, footprintBytes: footprint))
        }
        previous = next
        return out
    }

    /// Forget the baseline, e.g. when the page closes, so the next sweep does not average over minutes.
    public func reset() { previous = [:] }
}
