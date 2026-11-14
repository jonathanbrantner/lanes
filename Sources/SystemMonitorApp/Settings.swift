import SwiftUI
import SystemMonitorCore

/// Things that can be shown in the menu bar icon and/or the panel.
enum MonitorItem: String, CaseIterable, Identifiable {
    case memory, drives, disk, power, cpu, gpu, thermal, network, devices

    var id: String { rawValue }

    var title: String {
        switch self {
        case .memory: "Memory"
        case .drives: "External drives"
        case .disk: "Internal disk"
        case .power: "Power"
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .thermal: "Avg temp & fan"
        case .network: "Network"
        case .devices: "Batteries"
        }
    }

    var symbol: String {
        switch self {
        case .memory: "memorychip"
        case .drives: "externaldrive.fill"
        case .disk: "internaldrive.fill"
        case .power: "bolt.fill"
        case .cpu: "cpu"
        case .gpu: "display"
        case .thermal: "thermometer.medium"
        case .network: "network"
        case .devices: "battery.75percent"
        }
    }

    /// One colour per item, used in the menu bar, the panel and settings.
    var nsColor: NSColor {
        switch self {
        case .memory: .systemGreen
        case .drives: .systemBlue
        case .disk: .systemTeal
        case .power: .systemYellow
        case .cpu: .systemIndigo
        case .gpu: .systemPurple
        case .thermal: .systemRed
        case .network: .systemCyan
        case .devices: .systemPink
        }
    }

    var color: Color { Color(nsColor: nsColor) }
}

/// User choices, saved in UserDefaults so they survive quitting the app.
@MainActor
final class Settings: ObservableObject {
    private static let menuBarKey = "menuBarItems"
    private static let panelKey = "panelItems"
    private static let hiddenKey = "hiddenDrives"
    private static let intervalKey = "updateInterval"
    private static let showTempKey = "showTemperatures"
    private static let unitKey = "temperatureUnit"
    private static let chipKey = "chipOverride"

    static let intervals: [TimeInterval] = [1, 2, 5]

    /// Seconds between readings. Longer = fewer wake-ups.
    @Published var updateInterval: TimeInterval {
        didSet { UserDefaults.standard.set(updateInterval, forKey: Self.intervalKey) }
    }

    /// Show a temperature inside the CPU, GPU, Memory and Internal disk sections.
    @Published var showTemperatures: Bool {
        didSet { UserDefaults.standard.set(showTemperatures, forKey: Self.showTempKey) }
    }
    /// The item whose full page is open in the panel (nil = the tile overview). Not saved: the panel
    /// always opens on the tiles. Opening the CPU or GPU page is what shows its cores or sensors.
    @Published var openDetail: MonitorItem?

    /// The core views are only worth sampling while their page is open is open.
    var cpuCoresVisible: Bool { openDetail == .cpu }
    var gpuDetailVisible: Bool { openDetail == .gpu }
    /// The busiest-apps lists are only read while the CPU or Memory page is open.
    /// The all-sensors list is only read while its page is open.
    var sensorsVisible: Bool { openDetail == .thermal }
    var processesVisible: Bool { openDetail == .cpu || openDetail == .memory }

    /// Temperature unit. Readings are always collected in °C and converted when shown.
    @Published var useFahrenheit: Bool {
        didSet { UserDefaults.standard.set(useFahrenheit, forKey: Self.unitKey) }
    }
    /// Memory, CPU and GPU as small meters instead of icons or names (the other items use icons).
    @Published var menuBarMeters: Bool {
        didSet { UserDefaults.standard.set(menuBarMeters, forKey: "menuBarMeters") }
    }
    /// Menu bar style: false = short names (MEM, CPU ...), true = coloured icons with shorter text.
    @Published var menuBarIcons: Bool {
        didSet { UserDefaults.standard.set(menuBarIcons, forKey: "menuBarIcons") }
    }
    /// Show the CPU and GPU temperature in the menu bar too (red, after the load).
    @Published var menuBarTemperatures: Bool {
        didSet { UserDefaults.standard.set(menuBarTemperatures, forKey: "menuBarTemperatures") }
    }
    /// nil = detect from this Mac's CPU name.
    @Published var chipOverride: ChipFamily? {
        didSet { UserDefaults.standard.set(chipOverride?.rawValue, forKey: Self.chipKey) }
    }
    /// The chip whose sensor keys are used.
    var chip: ChipFamily { chipOverride ?? ChipFamily.detect() }

    /// "46°C" or "115°F"; with `symbol: false` just "46°" (menu bar, where space is tight).
    func temperature(_ celsius: Double, symbol: Bool = true) -> String {
        let value = useFahrenheit ? celsius * 9 / 5 + 32 : celsius
        let unit = symbol ? (useFahrenheit ? "F" : "C") : ""
        return String(format: "%.0f°%@", value, unit)
    }

    @Published var menuBarItems: Set<MonitorItem> {
        didSet { UserDefaults.standard.set(menuBarItems.map(\.rawValue), forKey: Self.menuBarKey) }
    }
    @Published var panelItems: Set<MonitorItem> {
        didSet { UserDefaults.standard.set(panelItems.map(\.rawValue), forKey: Self.panelKey) }
    }
    /// External drives the user switched off, by volume name.
    @Published var hiddenDrives: Set<String> {
        didSet { UserDefaults.standard.set(Array(hiddenDrives), forKey: Self.hiddenKey) }
    }

    init() {
        menuBarItems = Self.load(Self.menuBarKey, default: [.memory, .drives])
        panelItems = Self.load(Self.panelKey, default: Set(MonitorItem.allCases))
        hiddenDrives = Set(UserDefaults.standard.stringArray(forKey: Self.hiddenKey) ?? [])
        showTemperatures = UserDefaults.standard.object(forKey: Self.showTempKey) as? Bool ?? true
        useFahrenheit = UserDefaults.standard.bool(forKey: Self.unitKey)
        menuBarIcons = UserDefaults.standard.bool(forKey: "menuBarIcons")
        menuBarMeters = UserDefaults.standard.bool(forKey: "menuBarMeters")
        menuBarTemperatures = UserDefaults.standard.object(forKey: "menuBarTemperatures") as? Bool ?? true
        chipOverride = UserDefaults.standard.string(forKey: Self.chipKey).flatMap(ChipFamily.init(rawValue:))
        let saved = UserDefaults.standard.double(forKey: Self.intervalKey)
        updateInterval = Self.intervals.contains(saved) ? saved : 1
        // The Avg temp & fan item is new: switch it on in the panel once for existing installs,
        // since those two numbers used to sit under Power.
        // Network and Batteries are new in 2.1: show them in the panel once for existing installs.
        if !UserDefaults.standard.bool(forKey: "migratedNetworkBatteries") {
            UserDefaults.standard.set(true, forKey: "migratedNetworkBatteries")
            if UserDefaults.standard.stringArray(forKey: Self.panelKey) != nil {
                panelItems.formUnion([.network, .devices])
            }
        }
        if !UserDefaults.standard.bool(forKey: "migratedAvgTempItem") {
            UserDefaults.standard.set(true, forKey: "migratedAvgTempItem")
            if UserDefaults.standard.stringArray(forKey: Self.panelKey) != nil {
                panelItems.insert(.thermal)
            }
        }
    }

    private static func load(_ key: String, default fallback: Set<MonitorItem>) -> Set<MonitorItem> {
        guard let raw = UserDefaults.standard.stringArray(forKey: key) else { return fallback }
        return Set(raw.compactMap(MonitorItem.init(rawValue:)))
    }

    func menuBarBinding(_ item: MonitorItem) -> Binding<Bool> {
        Binding(get: { self.menuBarItems.contains(item) },
                set: { on in
                    if on { self.menuBarItems.insert(item) } else { self.menuBarItems.remove(item) }
                })
    }

    func panelBinding(_ item: MonitorItem) -> Binding<Bool> {
        Binding(get: { self.panelItems.contains(item) },
                set: { on in
                    if on { self.panelItems.insert(item) } else { self.panelItems.remove(item) }
                })
    }

    func driveBinding(_ label: String) -> Binding<Bool> {
        Binding(get: { !self.hiddenDrives.contains(label) },
                set: { on in
                    if on { self.hiddenDrives.remove(label) } else { self.hiddenDrives.insert(label) }
                })
    }
}
