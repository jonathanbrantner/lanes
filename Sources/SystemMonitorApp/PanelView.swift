import SwiftUI
import ServiceManagement
import SystemMonitorCore

/// Start-at-login toggle. Off by default; nothing is registered unless the user turns it on.
/// macOS asks the user to approve it in System Settings > Login Items.
@MainActor
final class LoginItem: ObservableObject {
    @Published var status = SMAppService.mainApp.status
    @Published var error: String?

    var isOn: Bool { status == .enabled || status == .requiresApproval }
    var needsApproval: Bool { status == .requiresApproval }

    func refresh() { status = SMAppService.mainApp.status }

    func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

struct PanelView: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject private var settings: Settings
    @StateObject private var loginItem = LoginItem()
    @State private var showSettings = false

    init(monitor: Monitor) {
        self.monitor = monitor
        self.settings = monitor.settings
    }

    var body: some View {
        Group {
            if showSettings {
                SettingsView(monitor: monitor, settings: settings, loginItem: loginItem) {
                    showSettings = false
                }
            } else {
                mainPanel
            }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { loginItem.refresh() }
    }

    // MARK: Main panel

    private var mainPanel: some View {
        let sections = visibleSections
        return VStack(alignment: .leading, spacing: 12) {
            if sections.isEmpty {
                Text("Nothing selected. Open Settings to choose what to show.")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(sections.enumerated()), id: \.element) { index, item in
                if index > 0 { Divider() }
                section(for: item)
            }
            Divider()
            HStack {
                Button("Settings") { showSettings = true }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
    }

    private var visibleSections: [MonitorItem] {
        MonitorItem.allCases.filter { item in
            guard settings.panelItems.contains(item) else { return false }
            switch item {
            case .gpu: return monitor.gpu != nil
            case .power: return monitor.power != nil
            case .temperature: return monitor.thermal != nil
            default: return true
            }
        }
    }

    @ViewBuilder
    private func section(for item: MonitorItem) -> some View {
        switch item {
        case .memory: memorySection
        case .drives: drivesSection
        case .disk: diskSection
        case .cpu: percentSection(.cpu, value: monitor.cpu, history: monitor.cpuHistory)
        case .gpu: percentSection(.gpu, value: monitor.gpu, history: monitor.gpuHistory)
        case .power: powerSection
        case .temperature: temperatureSection
        }
    }

    // MARK: Power

    private var powerSection: some View {
        let peak = max(15, monitor.powerHistory.max() ?? 15)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                header(.power)
                Spacer()
                if let watts = monitor.power?.systemWatts {
                    Text(String(format: "%.1f W", watts)).monospacedDigit()
                }
            }
            HistoryChart(values: monitor.powerHistory.map { $0 / peak }, color: MonitorItem.power.color)
                .frame(height: 36)
            HStack {
                Text("Whole system").foregroundStyle(.secondary)
                Spacer()
                if let gpu = monitor.power?.gpuWatts {
                    Text(String(format: "GPU %.2f W", gpu)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
    }

    // MARK: Temperature

    private var temperatureSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                header(.temperature)
                Spacer()
                if let c = monitor.thermal?.cpuC {
                    Text(settings.temperature(c)).monospacedDigit()
                }
            }
            // Chart scale: 30 °C (idle) to 100 °C (hot).
            HistoryChart(values: monitor.tempHistory.map { min(max(($0 - 30) / 70, 0), 1) },
                         color: MonitorItem.temperature.color)
                .frame(height: 36)
            HStack {
                Text("CPU").foregroundStyle(.secondary)
                Spacer()
                if let gpu = monitor.thermal?.gpuC {
                    Text("GPU \(settings.temperature(gpu))").monospacedDigit().foregroundStyle(.secondary)
                }
                if let ssd = monitor.thermal?.ssdC {
                    Text("SSD \(settings.temperature(ssd))").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            if let fan = monitor.thermal?.fans.first {
                HStack {
                    Text("Fan").foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.0f RPM", fan.rpm)).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
    }

    // MARK: Memory

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                header(.memory)
                Spacer()
                if let ram = monitor.ram {
                    Text(pressureLabel(ram.pressure)).foregroundStyle(pressureColor(ram.pressure))
                }
            }
            if let ram = monitor.ram {
                Text("\(bytes(ram.usedBytes)) of \(bytes(ram.totalBytes)) used")
                HistoryChart(values: monitor.ramHistory, color: pressureColor(ram.pressure))
                    .frame(height: 40)
                MemoryBar(ram: ram).frame(height: 8)
                VStack(spacing: 3) {
                    legend("App Memory", ram.appBytes, .blue)
                    legend("Wired", ram.wiredBytes, .orange)
                    legend("Compressed", ram.compressedBytes, .purple)
                }
                .font(.caption)
                HStack {
                    Text("Cached files \(bytes(ram.cachedBytes))")
                    Spacer()
                    Text("Swap used \(bytes(ram.swapUsedBytes))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text("Unavailable").foregroundStyle(.secondary)
            }
        }
    }

    private func legend(_ title: String, _ value: UInt64, _ color: Color?) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color ?? .clear).frame(width: 7, height: 7)
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 2)
            Text(bytes(value)).monospacedDigit()
        }
    }

    // MARK: External drives and internal disk

    private var drivesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            header(.drives)
            if monitor.externalDrives.isEmpty {
                Text(monitor.connectedExternalLabels.isEmpty ? "No external drive connected"
                                                              : "All external drives are hidden in Settings")
                    .foregroundStyle(.secondary)
            }
            ForEach(monitor.externalDrives, id: \.bsdName) { drive in
                driveRow(drive)
            }
        }
    }

    private var diskSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            header(.disk)
            if let drive = monitor.internalDrive {
                driveRow(drive)
            } else {
                Text("Waiting for data").foregroundStyle(.secondary)
            }
        }
    }

    private func driveRow(_ drive: DriveRate) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(drive.label).font(.subheadline)
            HStack {
                Label { Text(Monitor.speed(drive.readMBps)) } icon: { Image(systemName: "arrow.down").foregroundStyle(.blue) }
                Spacer()
                Label { Text(Monitor.speed(drive.writeMBps)) } icon: { Image(systemName: "arrow.up").foregroundStyle(.orange) }
            }
            .font(.system(.body, design: .monospaced))
            Sparkline(samples: monitor.driveHistory[drive.bsdName] ?? [])
                .frame(height: 32)
        }
    }

    // MARK: CPU / GPU

    private func percentSection(_ item: MonitorItem, value: Double?, history: [Double]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                header(item)
                Spacer()
                Text(value.map { String(format: "%.0f%%", $0 * 100) } ?? "n/a").monospacedDigit()
            }
            HistoryChart(values: history, color: item.color).frame(height: 36)
        }
    }

    /// Section title with the item's colour icon.
    private func header(_ item: MonitorItem) -> some View {
        HStack(spacing: 6) {
            Image(systemName: item.symbol).foregroundStyle(item.color)
            Text(item.title).font(.headline)
        }
    }

    // MARK: Formatting

    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }

    private func pressureLabel(_ p: MemoryPressure) -> String {
        switch p {
        case .normal: "Normal"
        case .warning: "Under pressure"
        case .critical: "Critical"
        }
    }

    private func pressureColor(_ p: MemoryPressure) -> Color {
        switch p {
        case .normal: .green
        case .warning: .orange
        case .critical: .red
        }
    }
}

// MARK: - Charts

/// Filled history chart for a 0...1 value over the last 60 seconds.
struct HistoryChart: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let points = chartPoints(in: geo.size)
            ZStack {
                Path { p in
                    guard let first = points.first, let last = points.last, points.count > 1 else { return }
                    p.move(to: CGPoint(x: first.x, y: geo.size.height))
                    points.forEach { p.addLine(to: $0) }
                    p.addLine(to: CGPoint(x: last.x, y: geo.size.height))
                    p.closeSubpath()
                }
                .fill(color.opacity(0.25))
                Path { p in
                    guard let first = points.first else { return }
                    p.move(to: first)
                    points.dropFirst().forEach { p.addLine(to: $0) }
                }
                .stroke(color, lineWidth: 1.5)
            }
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    private func chartPoints(in size: CGSize) -> [CGPoint] {
        let step = size.width / CGFloat(Monitor.historyLength - 1)
        let startX = size.width - step * CGFloat(max(values.count - 1, 0))
        return values.enumerated().map { index, value in
            CGPoint(x: startX + step * CGFloat(index),
                    y: size.height - size.height * CGFloat(min(max(value, 0), 1)))
        }
    }
}

/// Stacked bar of what counts as used: app, wired, compressed, and other (grey). Adds up to the headline.
struct MemoryBar: View {
    let ram: RAMSnapshot

    var body: some View {
        GeometryReader { geo in
            let total = Double(max(ram.totalBytes, 1))
            HStack(spacing: 0) {
                segment(Double(ram.appBytes), total, geo.size.width, .blue)
                segment(Double(ram.wiredBytes), total, geo.size.width, .orange)
                segment(Double(ram.compressedBytes), total, geo.size.width, .purple)
                segment(Double(ram.otherBytes), total, geo.size.width, .gray.opacity(0.7))
                Spacer(minLength: 0)
            }
            .background(Color.primary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
    }

    private func segment(_ value: Double, _ total: Double, _ width: CGFloat, _ color: Color) -> some View {
        Rectangle().fill(color).frame(width: width * CGFloat(min(value / total, 1)))
    }
}

/// Last 60 seconds of read (blue) and write (orange) speed.
struct Sparkline: View {
    let samples: [DriveSample]

    var body: some View {
        GeometryReader { geo in
            let peak = max(1, samples.map { max($0.read, $0.write) }.max() ?? 1)
            ZStack {
                line(samples.map(\.read), peak: peak, in: geo.size).stroke(Color.blue, lineWidth: 1.5)
                line(samples.map(\.write), peak: peak, in: geo.size).stroke(Color.orange, lineWidth: 1.5)
            }
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    private func line(_ values: [Double], peak: Double, in size: CGSize) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        let step = size.width / CGFloat(Monitor.historyLength - 1)
        let startX = size.width - step * CGFloat(values.count - 1)
        for (i, v) in values.enumerated() {
            let point = CGPoint(x: startX + step * CGFloat(i),
                                y: size.height - size.height * CGFloat(v / peak))
            i == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        return path
    }
}
