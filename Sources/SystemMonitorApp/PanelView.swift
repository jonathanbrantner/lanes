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
    /// The item whose full page is open (opened by clicking its tile); nil = the tile overview.
    /// Kept in Settings so the sampler knows when a core view is on screen.
    private var detail: MonitorItem? {
        get { settings.openDetail }
        nonmutating set { settings.openDetail = newValue }
    }

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
            } else if let item = detail {
                detailPage(item)
            } else {
                mainPanel
            }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { loginItem.refresh() }
    }

    // MARK: Main panel

    private static let tileOrder: [MonitorItem] = [.cpu, .gpu, .memory, .power, .drives, .disk]
    /// Only these have more to show than their tile: cores and sensors, and the memory breakdown.
    private static let pageItems: Set<MonitorItem> = [.cpu, .gpu, .memory]

    private var mainPanel: some View {
        let visible = visibleSections
        let tiles = Self.tileOrder.filter(visible.contains)
        return VStack(alignment: .leading, spacing: 10) {
            if visible.isEmpty {
                Text("Nothing selected. Open Settings to choose what to show.")
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(tiles, id: \.self) { item in
                    if let data = tileData(item) {
                        Tile(data: data, action: Self.pageItems.contains(item) ? { detail = item } : nil)
                    }
                }
            }
            if visible.contains(.thermal) { thermalStrip }
            HStack {
                Button("Settings") { showSettings = true }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .padding(.top, 2)
        }
    }

    /// One item's full section (the chart, legend, cores ...), reached from its tile.
    private func detailPage(_ item: MonitorItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { detail = nil } label: { Label("Back", systemImage: "chevron.left") }
                .buttonStyle(.borderless)
            section(for: item)
        }
    }

    /// Average temperature and fan speed as one line under the tiles.
    private var thermalStrip: some View {
        HStack(spacing: 6) {
            Image(systemName: "thermometer.medium").foregroundStyle(MonitorItem.thermal.color)
            if let avg = monitor.thermal?.averageC {
                Text("Avg \(settings.temperature(avg))").font(.system(size: 12, design: .monospaced))
            }
            if let fan = monitor.thermal?.fans.first {
                Text("·").foregroundStyle(.secondary)
                Text(String(format: "Fan %.0f RPM", fan.rpm)).font(.system(size: 12, design: .monospaced))
            }
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Tiles

    private func percent(_ value: Double?) -> String { value.map { String(format: "%.0f%%", $0 * 100) } ?? "n/a" }

    /// "↓412 ↑186": whole numbers once a speed is 10 MB/s or more.
    private func rates(_ read: Double, _ write: Double) -> String {
        func f(_ v: Double) -> String { String(format: v >= 10 ? "%.0f" : "%.1f", v) }
        return "↓\(f(read)) ↑\(f(write))"
    }

    /// Read plus write as one number per sample, zoomed like the other tiles.
    private func driveHistory(_ drive: DriveRate?) -> [Double] {
        guard let drive, let samples = monitor.driveHistory[drive.bsdName] else { return [] }
        return zoomed(samples.map { $0.read + $0.write }, minSpan: 1, floor: 0)
    }

    private func tileData(_ item: MonitorItem) -> TileData? {
        switch item {
        case .cpu:
            return TileData(id: item, symbol: item.symbol, name: item.title, color: item.color,
                            big: percent(monitor.cpu), small: "\(ProcessInfo.processInfo.activeProcessorCount) cores",
                            corner: shownTemp(monitor.thermal?.cpuC),
                            history: zoomed(monitor.cpuHistory, minSpan: 0.15, floor: 0))
        case .gpu:
            return TileData(id: item, symbol: item.symbol, name: item.title, color: item.color,
                            big: percent(monitor.gpu),
                            small: monitor.gpuDetail.map { "Renderer \(percent($0.renderer))" } ?? "Graphics",
                            corner: shownTemp(monitor.thermal?.gpuC),
                            history: zoomed(monitor.gpuHistory, minSpan: 0.15, floor: 0))
        case .memory:
            guard let ram = monitor.ram else { return nil }
            let warning = ram.pressure == .normal ? nil : (ram.pressure == .warning ? "Pressure" : "Critical")
            return TileData(id: item, symbol: item.symbol, name: item.title, color: pressureColor(ram.pressure),
                            big: percent(ram.usedFraction),
                            small: "\(bytes(ram.usedBytes)) of \(bytes(ram.totalBytes))",
                            corner: shownTemp(monitor.thermal?.ramC) ?? warning,
                            cornerColor: shownTemp(monitor.thermal?.ramC) == nil ? pressureColor(ram.pressure) : .red,
                            history: zoomed(monitor.ramHistory, minSpan: 0.04, floor: 0))
        case .power:
            return TileData(id: item, symbol: item.symbol, name: item.title, color: item.color,
                            big: monitor.power?.systemWatts.map { String(format: "%.1f W", $0) } ?? "n/a",
                            small: monitor.power?.gpuWatts.map { String(format: "GPU %.2f W", $0) } ?? "Whole system",
                            corner: nil, history: zoomed(monitor.powerHistory, minSpan: 3, floor: 0))
        case .drives:
            let drives = monitor.externalDrives
            guard let first = drives.first else {
                return TileData(id: item, symbol: item.symbol, name: "Drives", color: item.color,
                                big: "-", small: "No external drive", corner: nil, history: [])
            }
            return TileData(id: item, symbol: item.symbol,
                            name: drives.count == 1 ? first.label : "\(drives.count) drives", color: item.color,
                            big: Monitor.speed(monitor.externalRead + monitor.externalWrite),
                            small: rates(monitor.externalRead, monitor.externalWrite),
                            corner: nil, history: driveHistory(first))
        case .disk:
            guard let drive = monitor.internalDrive else {
                return TileData(id: item, symbol: item.symbol, name: "Disk", color: item.color,
                                big: "-", small: "Waiting for data", corner: nil, history: [])
            }
            return TileData(id: item, symbol: item.symbol, name: "Disk", color: item.color,
                            big: Monitor.speed(drive.readMBps + drive.writeMBps),
                            small: rates(drive.readMBps, drive.writeMBps),
                            corner: shownTemp(monitor.thermal?.ssdC), history: driveHistory(drive))
        case .thermal:
            return nil
        }
    }

    private var visibleSections: [MonitorItem] {
        MonitorItem.allCases.filter { item in
            guard settings.panelItems.contains(item) else { return false }
            switch item {
            case .gpu: return monitor.gpu != nil
            case .power: return monitor.power != nil
            case .thermal: return monitor.thermal?.averageC != nil || !(monitor.thermal?.fans.isEmpty ?? true)
            default: return true
            }
        }
    }

    @ViewBuilder
    private func section(for item: MonitorItem) -> some View {
        switch item {
        case .memory: memorySection
        case .cpu: percentSection(.cpu, value: monitor.cpu, history: monitor.cpuHistory,
                                  temp: shownTemp(monitor.thermal?.cpuC), tempHistory: monitor.cpuTempHistory,
                                  detail: { if settings.coreDetails { cpuCoresView } })
        case .gpu: percentSection(.gpu, value: monitor.gpu, history: monitor.gpuHistory,
                                  temp: shownTemp(monitor.thermal?.gpuC), tempHistory: monitor.gpuTempHistory,
                                  detail: { if settings.coreDetails { gpuDetailView } })
        default: EmptyView()
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
                tempChart(monitor.ramTempHistory, .red, label: shownTemp(monitor.thermal?.ramC))
                MemoryBar(ram: ram).frame(height: 8)
                VStack(spacing: 3) {
                    legend("App Memory", ram.appBytes, .blue)
                    legend("Wired", ram.wiredBytes, .orange)
                    legend("Compressed", ram.compressedBytes, .purple)
                    if ram.otherBytes > 0 { legend("Other", ram.otherBytes, .gray) }
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

    // MARK: CPU / GPU

    private func percentSection<Detail: View>(_ item: MonitorItem, value: Double?, history: [Double],
                                              temp: String?, tempHistory: [Double],
                                              @ViewBuilder detail: () -> Detail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                header(item)
                Spacer()
                Text(value.map { String(format: "%.0f%%", $0 * 100) } ?? "n/a").monospacedDigit()
            }
            HistoryChart(values: history, color: item.color).frame(height: 36)
            tempChart(tempHistory, .red, label: temp, labelColor: item == .cpu ? .red : .secondary)
            detail()
        }
    }

    // MARK: Cores

    private func clusterColor(_ kind: ClusterKind) -> Color {
        switch kind {
        case .superCore: .orange
        case .performance: .indigo
        case .efficiency: .teal
        }
    }

    /// One card per core class: its average load over time and temperature, then a small box with
    /// its own graph for every core in that class.
    private var cpuCoresView: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(monitor.topology.clusters, id: \.name) { cluster in clusterCard(cluster) }
        }
        .padding(.top, 2)
    }

    private func clusterCard(_ cluster: CPUCluster) -> some View {
        let color = clusterColor(cluster.kind)
        let loads = cluster.cpus.map { $0 < monitor.coreUsage.count ? monitor.coreUsage[$0] : nil }
        let known = loads.compactMap { $0 }
        let average = known.isEmpty ? nil : known.reduce(0, +) / Double(known.count)
        let histories = cluster.cpus.map { $0 < monitor.coreHistory.count ? monitor.coreHistory[$0] : [] }
        let columns = cluster.cpus.count <= 4 ? max(cluster.cpus.count, 1) : 3
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(cluster.name).font(.system(size: 12, weight: .semibold))
                Text("\(cluster.cpus.count) cores").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if settings.showTemperatures, let c = monitor.thermal?.clusterC[cluster.kind] {
                    Text(settings.temperature(c)).font(.caption).monospacedDigit().foregroundStyle(.red)
                }
                Text(percent(average)).font(.system(size: 12, design: .monospaced))
            }
            HistoryChart(values: zoomed(meanSeries(histories), minSpan: 0.15, floor: 0), color: color)
                .frame(height: 26)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: columns), spacing: 5) {
                ForEach(Array(cluster.cpus.enumerated()), id: \.element) { index, cpu in
                    MiniBox(title: "\(cpu)", value: loads[index].map { percent($0) } ?? "-",
                            history: zoomed(histories[index], minSpan: 0.25, floor: 0), color: color)
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    /// macOS reports no per-GPU-core numbers without admin rights, so the boxes are the three loads
    /// it does report and the GPU's individual temperature sensors (sensors, not cores).
    private var gpuDetailView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let d = monitor.gpuDetail {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 3), spacing: 5) {
                    MiniBox(title: "Device", value: percent(d.device),
                            history: zoomed(monitor.gpuHistory, minSpan: 0.1, floor: 0), color: MonitorItem.gpu.color)
                    MiniBox(title: "Renderer", value: percent(d.renderer),
                            history: zoomed(monitor.gpuRendererHistory, minSpan: 0.1, floor: 0), color: MonitorItem.gpu.color)
                    MiniBox(title: "Tiler", value: percent(d.tiler),
                            history: zoomed(monitor.gpuTilerHistory, minSpan: 0.1, floor: 0), color: MonitorItem.gpu.color)
                }
            } else {
                Text("Waiting for data").font(.caption).foregroundStyle(.secondary)
            }
            if settings.showTemperatures, let sensors = monitor.thermal?.gpuSensorsC, !sensors.isEmpty {
                HStack {
                    Text("GPU sensors").font(.caption.weight(.semibold))
                    Spacer()
                    Text("\(sensors.count) sensors, not cores").font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.top, 2)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 4), spacing: 5) {
                    ForEach(sensors.indices, id: \.self) { i in
                        MiniBox(title: "S\(i + 1)", value: settings.temperature(sensors[i], symbol: false),
                                history: zoomed(i < monitor.gpuSensorHistory.count ? monitor.gpuSensorHistory[i] : [], minSpan: 4),
                                color: .red)
                    }
                }
            }
        }
        .padding(.top, 2)
    }

    /// A thin chart of the recent temperature. It zooms to the recent range (at least 10 degrees tall)
    /// so small changes show up, and hides itself until there are a few readings.
    @ViewBuilder
    private func tempChart(_ history: [Double], _ color: Color, label: String? = nil,
                           labelColor: Color = .secondary) -> some View {
        if settings.showTemperatures, label != nil || history.count > 2 {
            HStack(spacing: 4) {
                if let label {
                    Text(label).font(.caption).monospacedDigit().foregroundStyle(labelColor)
                        .frame(width: 42, alignment: .leading)
                }
                Image(systemName: "thermometer.medium").font(.system(size: 10)).foregroundStyle(color).frame(width: 12)
                if history.count > 2 {
                    HistoryChart(values: zoomed(history, minSpan: 10), color: color).frame(height: 14)
                } else {
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// The temperature text for a section header, or nil when temperatures are off or unavailable.
    private func shownTemp(_ celsius: Double?) -> String? {
        guard settings.showTemperatures, let celsius else { return nil }
        return settings.temperature(celsius)
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
