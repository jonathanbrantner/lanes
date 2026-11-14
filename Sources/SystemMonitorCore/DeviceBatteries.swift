import Foundation
import IOKit

/// A connected Bluetooth device with a battery (mouse, keyboard, AirPods ...).
public struct DeviceBattery: Equatable {
    public let name: String
    /// Each part that reports a level, e.g. ("Left", 86), ("Right", 86), ("Case", 19); a single
    /// battery is ("", 74).
    public let parts: [(label: String, percent: Int)]

    public init(name: String, parts: [(label: String, percent: Int)]) {
        self.name = name
        self.parts = parts
    }

    /// The lowest level, the one that matters first.
    /// The charging case does not count when the devices themselves report a level.
    public var lowestPercent: Int {
        let devices = parts.filter { $0.label != "Case" }
        return (devices.isEmpty ? parts : devices).map(\.percent).min() ?? 0
    }

    public static func == (a: DeviceBattery, b: DeviceBattery) -> Bool {
        a.name == b.name && a.parts.elementsEqual(b.parts) { $0.label == $1.label && $0.percent == $1.percent }
    }
}

/// The Mac's own battery, only on laptops (a Mac mini or desktop reports none).
public struct LaptopBattery: Equatable {
    public let percent: Int
    public let isCharging: Bool
    public let onPower: Bool
    public let cycles: Int

    public init(percent: Int, isCharging: Bool, onPower: Bool, cycles: Int) {
        self.percent = percent
        self.isCharging = isCharging
        self.onPower = onPower
        self.cycles = cycles
    }
}

/// Bluetooth device batteries (from `system_profiler`, which answers in about 50 ms) and the laptop
/// battery (IORegistry `AppleSmartBattery`). Both change slowly: the app reads them once a minute.
public enum DeviceBatteries {
    /// Pure and testable: "86%" -> 86.
    public static func percent(_ text: String) -> Int? {
        Int(text.trimmingCharacters(in: CharacterSet(charactersIn: "% ")))
    }

    /// Pure and testable: the connected devices that report a battery, from `system_profiler -json`.
    public static func parseBluetooth(json data: Data) -> [DeviceBattery] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let section = (root["SPBluetoothDataType"] as? [[String: Any]])?.first,
              let connected = section["device_connected"] as? [[String: Any]] else { return [] }
        let labels: [(key: String, label: String)] = [
            ("device_batteryLevelMain", ""), ("device_batteryLevelLeft", "Left"),
            ("device_batteryLevelRight", "Right"), ("device_batteryLevelCase", "Case"),
        ]
        var out: [DeviceBattery] = []
        for entry in connected {
            for (name, value) in entry {
                guard let info = value as? [String: Any] else { continue }
                let parts: [(label: String, percent: Int)] = labels.compactMap { item in
                    (info[item.key] as? String).flatMap(percent).map { (item.label, $0) }
                }
                if !parts.isEmpty { out.append(DeviceBattery(name: name, parts: parts)) }
            }
        }
        return out.sorted { $0.name < $1.name }
    }

    public static func bluetooth() -> [DeviceBattery] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parseBluetooth(json: data)
    }

    /// nil on a Mac without a battery.
    public static func laptop() -> LaptopBattery? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        func value(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        guard (value("BatteryInstalled") as? Bool) == true,
              let current = (value("CurrentCapacity") as? NSNumber)?.intValue else { return nil }
        let max = (value("MaxCapacity") as? NSNumber)?.intValue ?? 100
        // Modern Macs report percent directly (max 100); older ones report mAh.
        let percent = max > 0 && max != 100 ? Int((Double(current) / Double(max) * 100).rounded()) : current
        return LaptopBattery(percent: Swift.min(100, Swift.max(0, percent)),
                             isCharging: (value("IsCharging") as? Bool) ?? false,
                             onPower: (value("ExternalConnected") as? Bool) ?? false,
                             cycles: (value("CycleCount") as? NSNumber)?.intValue ?? 0)
    }
}
