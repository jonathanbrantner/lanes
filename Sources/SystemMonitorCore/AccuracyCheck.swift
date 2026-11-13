import Foundation

/// One compared number: what Lanes shows against what macOS's own `vm_stat` reports.
public struct AccuracyLine: Equatable {
    public let name: String
    public let lanesGB: Double
    public let referenceGB: Double
    /// Relative difference in percent.
    public var differencePercent: Double { abs(lanesGB - referenceGB) / max(referenceGB, 1e-9) * 100 }
    public var isOK: Bool { differencePercent <= 1 }

    public init(name: String, lanesGB: Double, referenceGB: Double) {
        self.name = name
        self.lanesGB = lanesGB
        self.referenceGB = referenceGB
    }
}

/// "Check accuracy": compares Lanes' memory numbers with `vm_stat`, the reference tool macOS ships
/// (the same check `lanes-verify` runs). Activity Monitor itself cannot be read by other programs,
/// but it uses the same kernel counters as `vm_stat`.
public enum AccuracyCheck {
    /// Pure and testable: the reference numbers from `vm_stat` text.
    public static func reference(vmStat text: String, totalBytes: Double) -> (used: Double, app: Double, wired: Double, compressed: Double)? {
        var page = 16384.0
        if let first = text.split(separator: "\n").first,
           let range = first.range(of: "page size of "),
           let n = Double(first[range.upperBound...].prefix(while: \.isNumber)) { page = n }
        func pages(_ key: String) -> Double? {
            for line in text.split(separator: "\n") where line.hasPrefix(key) {
                let digits = line.split(separator: ":").last?.trimmingCharacters(in: CharacterSet(charactersIn: " .")) ?? ""
                return Double(digits)
            }
            return nil
        }
        guard let free = pages("Pages free"), let file = pages("File-backed pages"),
              let anon = pages("Anonymous pages"), let purgeable = pages("Pages purgeable"),
              let wired = pages("Pages wired down"), let compressor = pages("Pages occupied by compressor")
        else { return nil }
        let gb = 1_073_741_824.0
        return ((totalBytes - free * page - file * page) / gb, (anon - purgeable) * page / gb,
                wired * page / gb, compressor * page / gb)
    }

    /// Runs `vm_stat` and compares. Takes about 50 ms; call from a background queue.
    public static func run(snapshot: RAMSnapshot) -> [AccuracyLine]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/vm_stat")
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let ref = reference(vmStat: String(decoding: data, as: UTF8.self), totalBytes: Double(snapshot.totalBytes))
        else { return nil }
        let gb = 1_073_741_824.0
        return [
            AccuracyLine(name: "Memory used", lanesGB: Double(snapshot.usedBytes) / gb, referenceGB: ref.used),
            AccuracyLine(name: "App memory", lanesGB: Double(snapshot.appBytes) / gb, referenceGB: ref.app),
            AccuracyLine(name: "Wired", lanesGB: Double(snapshot.wiredBytes) / gb, referenceGB: ref.wired),
            AccuracyLine(name: "Compressed", lanesGB: Double(snapshot.compressedBytes) / gb, referenceGB: ref.compressed),
        ]
    }
}
