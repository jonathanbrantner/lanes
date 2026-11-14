import Foundation
import Darwin

/// Download and upload speed of one network connection, in bytes per second.
public struct NetworkRate: Equatable {
    public let bsdName: String      // e.g. "en0"
    public let label: String        // "Wi-Fi", "Ethernet" ...
    public let downBytesPerSec: Double
    public let upBytesPerSec: Double

    public init(bsdName: String, label: String, downBytesPerSec: Double, upBytesPerSec: Double) {
        self.bsdName = bsdName
        self.label = label
        self.downBytesPerSec = downBytesPerSec
        self.upBytesPerSec = upBytesPerSec
    }

    public var downMBps: Double { downBytesPerSec / 1_000_000 }
    public var upMBps: Double { upBytesPerSec / 1_000_000 }
}

/// Per-connection byte counters from `getifaddrs`, no admin rights. Only real connections count
/// (en0, en1 ... that are up); loopback, VPN tunnels and Apple's internal links are left out so
/// traffic is never counted twice. The counters are 32 bit and wrap, which `delta` handles.
public final class NetworkCollector {
    private var previous: [String: (down: UInt32, up: UInt32, time: TimeInterval)] = [:]
    private var labels: [String: String] = [:]

    public init() { labels = Self.friendlyNames() }

    /// Pure and testable: bytes added since `old`, correct across one wrap of the 32 bit counter.
    public static func delta(old: UInt32, new: UInt32) -> UInt64 { UInt64(new &- old) }

    /// Which interface names are physical connections worth showing.
    public static func isPhysical(_ name: String) -> Bool {
        name.hasPrefix("en") && name.count > 2 && name.dropFirst(2).allSatisfy(\.isNumber)
    }

    public func rates() -> [NetworkRate] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }

        let now = ProcessInfo.processInfo.systemUptime
        var out: [NetworkRate] = []
        var next: [String: (down: UInt32, up: UInt32, time: TimeInterval)] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let data = entry.pointee.ifa_data else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            guard Self.isPhysical(name) else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            next[name] = (stats.ifi_ibytes, stats.ifi_obytes, now)
            guard let prev = previous[name], now > prev.time else { continue }
            let dt = now - prev.time
            let label = labels[name] ?? name
            out.append(NetworkRate(bsdName: name, label: label,
                                   downBytesPerSec: Double(Self.delta(old: prev.down, new: stats.ifi_ibytes)) / dt,
                                   upBytesPerSec: Double(Self.delta(old: prev.up, new: stats.ifi_obytes)) / dt))
        }
        previous = next
        return out.sorted { $0.bsdName < $1.bsdName }
    }

    /// Pure and testable: "Hardware Port: Wi-Fi / Device: en0" pairs out of `networksetup -listallhardwareports`.
    public static func parseHardwarePorts(_ text: String) -> [String: String] {
        var map: [String: String] = [:]
        var port: String?
        for line in text.split(separator: "\n") {
            if line.hasPrefix("Hardware Port: ") { port = String(line.dropFirst("Hardware Port: ".count)) }
            else if line.hasPrefix("Device: "), let name = port { map[String(line.dropFirst("Device: ".count))] = name; port = nil }
        }
        return map
    }

    /// "en0" -> "Wi-Fi". Asked of the `networksetup` tool once instead of loading the SystemConfiguration
    /// framework into Lanes, which cost about 20 MB of memory for the whole life of the app.
    private static func friendlyNames() -> [String: String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-listallhardwareports"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parseHardwarePorts(String(decoding: data, as: UTF8.self))
    }
}
