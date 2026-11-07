import SwiftUI

/// Things that can be shown in the menu bar icon and/or the panel.
enum MonitorItem: String, CaseIterable, Identifiable {
    case memory, drives, disk, power, cpu, gpu, temperature

    var id: String { rawValue }

    var title: String {
        switch self {
        case .memory: "Memory"
        case .drives: "External drives"
        case .disk: "Internal disk"
        case .power: "Power"
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .temperature: "Temperature"
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
        case .temperature: "thermometer.medium"
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
        case .temperature: .systemRed
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

    static let intervals: [TimeInterval] = [1, 2, 5]

    /// Seconds between readings. Longer = fewer wake-ups.
    @Published var updateInterval: TimeInterval {
        didSet { UserDefaults.standard.set(updateInterval, forKey: Self.intervalKey) }
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
        let saved = UserDefaults.standard.double(forKey: Self.intervalKey)
        updateInterval = Self.intervals.contains(saved) ? saved : 1
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
