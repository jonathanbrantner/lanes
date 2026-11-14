import Foundation
import CPower

/// One reading on the sensors page.
public struct SensorReading: Equatable {
    public enum Kind: Int, CaseIterable { case temperature, fan, power, voltage, current }

    public let kind: Kind
    public let name: String
    public let value: Double

    public init(kind: Kind, name: String, value: Double) {
        self.kind = kind
        self.name = name
        self.value = value
    }

    public var unit: String {
        switch kind {
        case .temperature: "°C"
        case .fan: "rpm"
        case .power: "W"
        case .voltage: "V"
        case .current: "A"
        }
    }
}

/// Every temperature, fan, power, voltage and current reading this Mac offers without admin rights:
/// the IOHID temperature sensors and the SMC keys. The SMC key list (about 2000 keys) is scanned once
/// to find the keys that hold a plausible number; after that each read touches only those.
public final class SensorsCollector {
    private var keys: [(key: String, kind: SensorReading.Kind)]?

    public init() {}

    /// Pure and testable: which kind of reading an SMC key holds, from its first letter.
    public static func kind(forKey key: String) -> SensorReading.Kind? {
        switch key.first {
        case "T": .temperature
        case "F": key.hasSuffix("Ac") || key.hasSuffix("Mn") || key.hasSuffix("Mx") || key.hasSuffix("Tg") ? .fan : nil
        case "P": .power
        case "V": .voltage
        case "I": .current
        default: nil
        }
    }

    /// Plain-language names for the keys that are known; others keep the raw 4-letter key.
    public static func friendlyName(forKey key: String) -> String {
        let known: [String: String] = [
            "PSTR": "System power", "PDTR": "Power adapter in", "PHPC": "Processor package power",
            "F0Ac": "Fan speed", "F0Mn": "Fan minimum", "F0Mx": "Fan maximum", "F0Tg": "Fan target",
        ]
        return known[key] ?? key
    }

    /// "PMU tdie4" -> "Chip die sensor 4", "NAND CH0" -> "SSD (NAND)".
    public static func friendlyName(forHID name: String) -> String {
        if name.hasPrefix("NAND") { return "SSD (NAND)" }
        if name.contains("tdie") { return "Chip die sensor " + name.drop { !$0.isNumber } }
        if name.contains("tdev") { return "Device sensor " + name.drop { !$0.isNumber } }
        if name.hasSuffix("tcal") { return "Calibration sensor" }
        return name
    }

    /// Plausible values only: a temperature between -20 and 150 degrees and so on, so keys that hold
    /// something else are left out.
    public static func isPlausible(_ value: Double, kind: SensorReading.Kind) -> Bool {
        guard value.isFinite else { return false }
        switch kind {
        case .temperature: return value > -20 && value < 150
        case .fan: return value >= 0 && value < 20000
        case .power: return value >= 0 && value < 1000
        case .voltage: return value >= 0 && value < 100
        case .current: return value >= 0 && value < 200
        }
    }

    public func read() -> [SensorReading] {
        var out: [SensorReading] = []
        guard lanes_smc_open() == 1 else { return hidReadings() }
        if keys == nil {
            keys = SMCKeys.all().compactMap { key in
                guard let kind = Self.kind(forKey: key) else { return nil }
                var v = 0.0
                var type = [CChar](repeating: 0, count: 5)
                guard lanes_smc_read_number(key, &v, &type) == 1, Self.isPlausible(v, kind: kind) else { return nil }
                return (key, kind)
            }
        }
        for (key, kind) in keys ?? [] {
            var v = 0.0
            var type = [CChar](repeating: 0, count: 5)
            guard lanes_smc_read_number(key, &v, &type) == 1, Self.isPlausible(v, kind: kind) else { continue }
            out.append(SensorReading(kind: kind, name: Self.friendlyName(forKey: key), value: v))
        }
        return hidReadings() + out
    }

    private func hidReadings() -> [SensorReading] {
        var sensors = [lanes_temp_sensor](repeating: lanes_temp_sensor(), count: 128)
        let n = Int(lanes_hid_temps_read(&sensors, 128))
        return (0..<max(n, 0)).compactMap { i in
            let name = withUnsafePointer(to: &sensors[i].name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 64) { String(cString: $0) }
            }
            guard Self.isPlausible(sensors[i].celsius, kind: .temperature) else { return nil }
            return SensorReading(kind: .temperature, name: Self.friendlyName(forHID: name), value: sensors[i].celsius)
        }
    }
}
