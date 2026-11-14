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
    /// The app bundle this process belongs to (for its icon), nil for command line tools.
    public let appPath: String?

    public init(pid: Int32, name: String, cpuPercent: Double, footprintBytes: UInt64, appPath: String? = nil) {
        self.pid = pid
        self.name = name
        self.cpuPercent = cpuPercent
        self.footprintBytes = footprintBytes
        self.appPath = appPath
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
            var pathBuffer = [CChar](repeating: 0, count: 4096)
            let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            let path = pathLength > 0 ? String(cString: pathBuffer) : ""
            let shown = Self.displayName(path: path, rawName: String(cString: nameBuffer))
            out.append(ProcessUsage(pid: pid, name: shown.name.isEmpty ? "pid \(pid)" : shown.name,
                                    cpuPercent: cpu, footprintBytes: footprint, appPath: shown.appPath))
        }
        previous = next
        return Self.combine(out)
    }

    /// A readable name and the app it belongs to, from the executable path and the raw process name.
    /// "Google Chrome Helper (Renderer)" inside "Google Chrome.app" is "Google Chrome"; an XPC service
    /// "com.apple.Virtualization.VirtualMachine" is "Virtualization.VirtualMachine"; "2.1.325" in
    /// ".../claude/versions/2.1.325" is "claude".
    public static func displayName(path: String, rawName: String) -> (name: String, appPath: String?) {
        let parts = path.split(separator: "/").map(String.init)
        if let i = parts.firstIndex(where: { $0.hasSuffix(".app") }) {
            let app = "/" + parts[0...i].joined(separator: "/")
            return (String(parts[i].dropLast(4)), app)
        }
        if let xpc = parts.last(where: { $0.hasSuffix(".xpc") }) {
            return (stripVendor(String(xpc.dropLast(4))), nil)
        }
        let isVersion = !rawName.isEmpty && rawName.allSatisfy { $0.isNumber || $0 == "." }
        if isVersion || rawName.isEmpty {
            let skip: Set<String> = ["versions", "bin", "current", "latest", "release", "releases"]
            if let parent = parts.dropLast().last(where: { !skip.contains($0) && !$0.allSatisfy { $0.isNumber || $0 == "." } }) {
                return (parent, nil)
            }
        }
        return (stripVendor(rawName), nil)
    }

    private static func stripVendor(_ name: String) -> String {
        name.hasPrefix("com.apple.") ? String(name.dropFirst("com.apple.".count)) : name
    }

    /// One entry per app: the app's helper processes are added together (like Activity Monitor's
    /// "combine"), so "Safari" is Safari and all its web content processes.
    public static func combine(_ list: [ProcessUsage]) -> [ProcessUsage] {
        var byName: [String: ProcessUsage] = [:]
        for p in list {
            if let existing = byName[p.name] {
                byName[p.name] = ProcessUsage(pid: existing.pid, name: p.name, cpuPercent: existing.cpuPercent + p.cpuPercent,
                                              footprintBytes: existing.footprintBytes + p.footprintBytes,
                                              appPath: existing.appPath ?? p.appPath)
            } else {
                byName[p.name] = p
            }
        }
        return Array(byName.values)
    }

    /// Forget the baseline, e.g. when the page closes, so the next sweep does not average over minutes.
    public func reset() { previous = [:] }
}
