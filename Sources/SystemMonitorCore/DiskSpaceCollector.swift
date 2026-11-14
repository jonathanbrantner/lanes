import Foundation

/// Free and total space of one mounted volume.
public struct VolumeSpace: Equatable {
    public let name: String
    public let totalBytes: UInt64
    public let freeBytes: UInt64
    public let isInternal: Bool

    public init(name: String, totalBytes: UInt64, freeBytes: UInt64, isInternal: Bool) {
        self.name = name
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.isInternal = isInternal
    }

    public var usedFraction: Double { totalBytes == 0 ? 0 : 1 - Double(freeBytes) / Double(totalBytes) }

    /// "412 GB free" (decimal gigabytes, like Finder).
    public var freeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(freeBytes), countStyle: .file) + " free"
    }
}

/// Disk health as reported by macOS (`diskutil info`): Apple SSDs and many NVMe drives say
/// "Verified"; drives behind a USB adapter often say "Not Supported", which is shown as nothing.
public enum SmartStatus: Equatable {
    case verified, failing
}

/// Free space per volume and S.M.A.R.T. status. Both change slowly, so the app reads them every
/// half minute (space) and every ten minutes (health, which starts a small `diskutil` process).
public final class DiskSpaceCollector {
    private var smartCache: [String: (status: SmartStatus?, time: Date)] = [:]
    public static let smartInterval: TimeInterval = 600

    public init() {}

    /// Mounted, user-visible volumes by name.
    public func volumes() -> [VolumeSpace] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey,
                                      .volumeAvailableCapacityForImportantUsageKey, .volumeIsInternalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)),
                  let name = v.volumeName, let total = v.volumeTotalCapacity, total > 0,
                  let free = v.volumeAvailableCapacityForImportantUsage else { return nil }
            return VolumeSpace(name: name, totalBytes: UInt64(total), freeBytes: UInt64(max(0, free)),
                               isInternal: v.volumeIsInternal ?? false)
        }
    }

    /// Pure and testable: the status out of `diskutil info -plist` output.
    public static func parseSmart(plist data: Data) -> SmartStatus? {
        guard let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let text = dict["SMARTStatus"] as? String else { return nil }
        switch text {
        case "Verified": return .verified
        case "Failing": return .failing
        default: return nil
        }
    }

    /// Health of `/dev/<bsdName>`, cached for ten minutes.
    public func smart(bsdName: String) -> SmartStatus? {
        if let cached = smartCache[bsdName], Date().timeIntervalSince(cached.time) < Self.smartInterval {
            return cached.status
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["info", "-plist", "/dev/\(bsdName)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        var status: SmartStatus?
        if (try? process.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            status = Self.parseSmart(plist: data)
        }
        smartCache[bsdName] = (status, Date())
        return status
    }
}
