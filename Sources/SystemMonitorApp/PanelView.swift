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
    @State private var showAllSensors = false
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

    private static let tileOrder: [MonitorItem] = [.cpu, .gpu, .memory, .network, .power, .thermal, .drives, .disk, .devices]
    /// Only these have more to show than their tile: cores and sensors, and the memory breakdown.
    private static let pageItems: Set<MonitorItem> = [.cpu, .gpu, .memory, .network, .thermal, .devices]

    private var mainPanel: some View {
        let visible = visibleSections
        let tiles = Self.tileOrder.filter(visible.contains)
        return VStack(alignment: .leading, spacing: 10) {
            if visible.isEmpty {
                Text("Nothing selected. Open Settings to choose what to show.")
                    .foregroundStyle(.secondary)
            }
            if settings.panelList {
                VStack(spacing: 6) {
                    ForEach(tiles, id: \.self) { item in
                        if let data = tileData(item) {
                            ListRow(data: data, action: Self.pageItems.contains(item) ? { detail = item } : nil)
                        }
                    }
                }
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(tiles, id: \.self) { item in
                        if let data = tileData(item) {
                            Tile(data: data, action: Self.pageItems.contains(item) ? { detail = item } : nil)
                        }
                    }
                }
            }
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

    // MARK: Tiles

    /// Hover readout for a graph that gets one sample per update tick.
    private func scrub(_ values: [Double], format: @escaping (Double) -> String) -> ScrubReadout {
        ScrubReadout(values: values, secondsPerSample: settings.updateInterval, format: format)
    }

    /// Same for a 0...1 load shown as a percentage.
    private func loadScrub(_ values: [Double]) -> ScrubReadout {
        scrub(values) { String(format: "%.0f%%", $0 * 100) }
    }

    /// Temperature sensors are read about every 3 seconds, in whole update intervals (see Sampler).
    private var sensorSeconds: Double {
        settings.updateInterval * max(1, (3.0 / settings.updateInterval).rounded(.up))
    }

    private func percent(_ value: Double?) -> String { value.map { String(format: "%.0f%%", $0 * 100) } ?? "n/a" }

    /// Whole numbers once a speed is 10 MB/s or more ("412", "0.2").
    private func rates(_ read: Double, _ write: Double) -> (read: String, write: String) {
        func f(_ v: Double) -> String { String(format: v >= 10 ? "%.0f" : "%.1f", v) }
        return (f(read), f(write))
    }

    /// Read plus write as one number per sample, zoomed like the other tiles.
    private func driveHistory(_ drive: DriveRate?) -> [Double] {
        guard let drive, let samples = monitor.driveHistory[drive.bsdName] else { return [] }
        return zoomed(samples.map { $0.read + $0.write }, minSpan: 1, floor: 0, padding: 0.5)
    }

    /// Free space of the volume that belongs to this drive (matched by volume name; the internal
    /// disk falls back to the largest internal volume).
    private func space(for drive: DriveRate) -> VolumeSpace? {
        let volumes = monitor.volumes
        if let match = volumes[drive.label] { return match }
        if let part = drive.label.components(separatedBy: ", ").compactMap({ volumes[$0] }).first { return part }
        return drive.isInternal ? volumes.values.filter(\.isInternal).max { $0.totalBytes < $1.totalBytes } : nil
    }

    /// Top right of a drive tile: "SMART ✗" in red if macOS reports the drive failing, else the free space ("412 GB").
    private func driveCorner(_ drive: DriveRate) -> (text: String?, color: Color) {
        if monitor.smart[drive.bsdName] == .failing { return ("SMART ✗", .red) }
        guard let space = space(for: drive) else { return (nil, .secondary) }
        let gb = Double(space.freeBytes) / 1e9
        return (gb >= 1000 ? String(format: "%.1f TB", gb / 1000) : String(format: "%.0f GB", gb), .secondary)
    }

    private func tileData(_ item: MonitorItem) -> TileData? {
        switch item {
        case .cpu:
            return TileData(id: item, symbol: item.symbol, name: item.title, color: item.color,
                            big: percent(monitor.cpu), small: "\(ProcessInfo.processInfo.activeProcessorCount) cores",
                            corner: shownTemp(monitor.thermal?.cpuC),
                            history: zoomed(monitor.cpuHistory, minSpan: 0.07, floor: 0, padding: 0.05))
        case .gpu:
            return TileData(id: item, symbol: item.symbol, name: item.title, color: item.color,
                            big: percent(monitor.gpu),
                            small: monitor.gpuCoreCount.map { "\($0) cores" } ?? "Graphics",
                            corner: shownTemp(monitor.thermal?.gpuC),
                            history: zoomed(monitor.gpuHistory, minSpan: 0.07, floor: 0, padding: 0.05))
        case .memory:
            guard let ram = monitor.ram else { return nil }
            let warning = ram.pressure == .normal ? nil : (ram.pressure == .warning ? "Pressure" : "Critical")
            return TileData(id: item, symbol: item.symbol, name: item.title, color: pressureColor(ram.pressure),
                            big: percent(ram.usedFraction),
                            small: "\(bytes(ram.usedBytes)) of \(bytes(ram.totalBytes))",
                            corner: shownTemp(monitor.thermal?.ramC) ?? warning,
                            cornerColor: shownTemp(monitor.thermal?.ramC) == nil ? pressureColor(ram.pressure) : .red,
                            history: zoomed(monitor.ramHistory, minSpan: 0.03, floor: 0, padding: 0.01))
        case .power:
            return TileData(id: item, symbol: item.symbol, name: item.title, color: item.color,
                            big: monitor.power?.systemWatts.map { String(format: "%.1f W", $0) } ?? "n/a",
                            small: monitor.power?.gpuWatts.map { String(format: "GPU %.2f W", $0) } ?? "Whole system",
                            corner: nil, history: zoomed(monitor.powerHistory, minSpan: 2, floor: 0, padding: 0.5))
        case .drives:
            let drives = monitor.externalDrives
            guard let first = drives.first else {
                return TileData(id: item, symbol: item.symbol, name: "Drives", color: item.color,
                                big: "-", small: "No external drive", corner: nil, history: [])
            }
            return TileData(id: item, symbol: item.symbol,
                            name: drives.count == 1 ? first.label : "\(drives.count) drives", color: item.color,
                            big: Monitor.speed(monitor.externalRead + monitor.externalWrite),
                            small: "", rates: rates(monitor.externalRead, monitor.externalWrite),
                            corner: driveCorner(first).text, cornerColor: driveCorner(first).color,
                            history: driveHistory(first))
        case .disk:
            guard let drive = monitor.internalDrive else {
                return TileData(id: item, symbol: item.symbol, name: "Disk", color: item.color,
                                big: "-", small: "", corner: nil, history: [])
            }
            return TileData(id: item, symbol: item.symbol, name: "Disk", color: item.color,
                            big: Monitor.speed(drive.readMBps + drive.writeMBps),
                            small: "", rates: rates(drive.readMBps, drive.writeMBps),
                            corner: shownTemp(monitor.thermal?.ssdC) ?? driveCorner(drive).text,
                            cornerColor: shownTemp(monitor.thermal?.ssdC) == nil ? driveCorner(drive).color : .red,
                            history: driveHistory(drive))
        case .network:
            guard !monitor.network.isEmpty else {
                return TileData(id: item, symbol: item.symbol, name: "Network", color: item.color,
                                big: "-", small: "No connection", corner: nil, history: [])
            }
            let combined = networkCombinedHistory()
            return TileData(id: item, symbol: item.symbol, name: "Network", color: item.color,
                            big: Monitor.speed(monitor.networkDown + monitor.networkUp),
                            small: "", rates: rates(monitor.networkDown, monitor.networkUp),
                            corner: nil, history: zoomed(combined, minSpan: 1, floor: 0, padding: 0.5))
        case .thermal:
            guard let avg = monitor.thermal?.averageC else { return nil }
            let fan = monitor.thermal?.fans.first.map { String(format: "Fan %.0f RPM", $0.rpm) }
            var data = TileData(id: item, symbol: item.symbol, name: "Avg temp", color: item.color,
                                big: settings.temperature(avg), small: pressureText(monitor.thermalPressure) ?? fan ?? "All sensors",
                                corner: nil, history: zoomed(monitor.avgTempHistory, minSpan: 4, padding: 1))
            data.fraction = min(1, avg / 100)
            return data
        case .devices:
            guard let lowest = monitor.lowestBattery else { return nil }
            let names = (monitor.laptopBattery == nil ? [] : ["This Mac"]) + monitor.deviceBatteries.map(\.name)
            var data = TileData(id: item, symbol: item.symbol, name: "Batteries", color: item.color,
                                big: "\(lowest)%", small: "\(names.count) device\(names.count == 1 ? "" : "s")",
                                corner: nil, history: [])
            // Every device on its own line (the lowest level is the big number).
            data.lines = (monitor.laptopBattery.map { [("This Mac", "\($0.percent)%")] } ?? [])
                + monitor.deviceBatteries.map { (shortDeviceName($0.name), "\($0.lowestPercent)%") }
            data.fraction = Double(lowest) / 100
            return data
        }
    }

    private var visibleSections: [MonitorItem] {
        MonitorItem.allCases.filter { item in
            guard settings.panelItems.contains(item) else { return false }
            switch item {
            case .gpu: return monitor.gpu != nil
            case .power: return monitor.power != nil
            case .network: return true
            case .devices: return !monitor.deviceBatteries.isEmpty || monitor.laptopBattery != nil
            case .thermal: return monitor.thermal?.averageC != nil || !(monitor.thermal?.fans.isEmpty ?? true)
            default: return true
            }
        }
    }

    @ViewBuilder
    private func section(for item: MonitorItem) -> some View {
        switch item {
        case .memory: memorySection
        case .network: networkSection
        case .thermal: sensorsSection
        case .devices: devicesSection
        case .cpu: percentSection(.cpu, value: monitor.cpu,
                                  history: zoomed(monitor.cpuHistory, minSpan: 0.07, floor: 0, padding: 0.05),
                                  scrub: loadScrub(monitor.cpuHistory),
                                  temp: shownTemp(monitor.thermal?.cpuC),
                                  detail: { VStack(alignment: .leading, spacing: 8) { cpuCoresView; busiestApps(byMemory: false) } })
        case .gpu: percentSection(.gpu, value: monitor.gpu,
                                  history: zoomed(monitor.gpuHistory, minSpan: 0.07, floor: 0, padding: 0.05),
                                  scrub: loadScrub(monitor.gpuHistory),
                                  temp: shownTemp(monitor.thermal?.gpuC),
                                  detail: { gpuDetailView })
        default: EmptyView()
        }
    }

    // MARK: Batteries page

    /// Expanded view: one card per device with a bar for every part (left, right, case).
    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            header(.devices)
            if let battery = monitor.laptopBattery {
                batteryCard("This Mac", symbol: "laptopcomputer",
                            parts: [("Battery", battery.percent)],
                            detail: [battery.isCharging ? "Charging" : (battery.onPower ? "On power, not charging" : "On battery"),
                                     "\(battery.cycles) charge cycles"])
            }
            ForEach(monitor.deviceBatteries, id: \.name) { device in
                batteryCard(device.name, symbol: deviceSymbol(device.name),
                            parts: device.parts.map { ($0.label.isEmpty ? "Battery" : $0.label, $0.percent) }, detail: [])
            }
            if monitor.deviceBatteries.isEmpty && monitor.laptopBattery == nil {
                Text("No device with a battery is connected.").foregroundStyle(.secondary)
            }
            Text("Updated about once a minute.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func deviceSymbol(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("airpods") { return "airpodspro" }
        if lower.contains("keyboard") || lower.contains("keys") { return "keyboard" }
        if lower.contains("mouse") || lower.contains("mx ") { return "computermouse" }
        if lower.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        return "dot.radiowaves.left.and.right"
    }

    private func batteryCard(_ name: String, symbol: String, parts: [(String, Int)], detail: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(MonitorItem.devices.color)
                Text(name).fontWeight(.semibold).lineLimit(1)
                Spacer()
            }
            ForEach(parts.indices, id: \.self) { i in
                let part = parts[i]
                HStack(spacing: 8) {
                    Text(part.0).font(.caption).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.12))
                            RoundedRectangle(cornerRadius: 4).fill(part.1 <= 20 ? Color.red : Color.green)
                                .frame(width: max(4, geo.size.width * CGFloat(part.1) / 100))
                        }
                    }
                    .frame(height: 10)
                    Text("\(part.1)%").font(.caption).monospacedDigit()
                        .foregroundStyle(part.1 <= 20 ? Color.red : Color.primary)
                        .frame(width: 38, alignment: .trailing)
                }
            }
            ForEach(detail, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Sensors

    /// Every temperature, fan, power, voltage and current reading, grouped.
    private var sensorsSection: some View {
        let readings = monitor.sensors
        let thermal = monitor.thermal
        // The few numbers that matter, then the long list only on request.
        var key: [(String, String, Color)] = []
        func temp(_ name: String, _ c: Double?) { if let c { key.append((name, settings.temperature(c), .red)) } }
        temp("CPU", thermal?.cpuC)
        temp("GPU", thermal?.gpuC)
        temp("Memory", thermal?.ramC)
        temp("SSD", thermal?.ssdC)
        if let dies = SensorsCollector.summary(readings, kind: .temperature, namePrefix: "die") {
            key.append(("Chip, \(dies.count) sensors", "avg \(settings.temperature(dies.average, symbol: false))  max \(settings.temperature(dies.maximum, symbol: false))", .red))
        }
        for fan in readings.filter({ $0.kind == .fan && $0.name == "Fan speed" }) { key.append((fan.name, sensorText(fan), .primary)) }
        for power in readings.filter({ $0.kind == .power }).prefix(3) { key.append((power.name, sensorText(power), .primary)) }
        return VStack(alignment: .leading, spacing: 8) {
            header(.thermal)
            if readings.isEmpty { Text("Waiting for data").foregroundStyle(.secondary) }
            VStack(spacing: 4) {
                ForEach(key.indices, id: \.self) { i in
                    HStack {
                        Text(key[i].0).foregroundStyle(.secondary)
                        Spacer(minLength: 6)
                        Text(key[i].1).monospacedDigit().foregroundStyle(key[i].2)
                    }
                    .font(.system(size: 12))
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            Button { showAllSensors.toggle() } label: {
                HStack {
                    Text(showAllSensors ? "Hide all readings" : "Show all \(readings.count) readings")
                    Spacer()
                    Image(systemName: showAllSensors ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold))
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            if showAllSensors {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(readings.indices, id: \.self) { i in
                            HStack {
                                Text(readings[i].name).lineLimit(1)
                                Spacer(minLength: 6)
                                Text(sensorText(readings[i])).monospacedDigit()
                                    .foregroundStyle(readings[i].kind == .temperature ? Color.red : Color.primary)
                            }
                            .font(.caption)
                        }
                    }
                    .padding(10)
                }
                .frame(maxHeight: 260)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func sensorText(_ r: SensorReading) -> String {
        switch r.kind {
        case .temperature: settings.temperature(r.value)
        case .fan: String(format: "%.0f rpm", r.value)
        case .power: String(format: "%.2f W", r.value)
        case .voltage: String(format: "%.2f V", r.value)
        case .current: String(format: "%.2f A", r.value)
        }
    }

    // MARK: Busiest apps

    /// The five busiest apps by CPU or by memory, on the CPU and Memory pages. Helper processes are added
    /// to their app, each row has the app's icon and a thin bar relative to the top one.
    private func busiestApps(byMemory: Bool) -> some View {
        let list = byMemory ? monitor.topByMemory : monitor.topByCPU
        let top = max(list.map { byMemory ? Double($0.footprintBytes) : $0.cpuPercent }.max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 6) {
            Text(byMemory ? "MOST MEMORY" : "BUSIEST APPS")
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).tracking(0.5)
            if list.isEmpty { Text("Waiting for data").font(.caption).foregroundStyle(.secondary) }
            ForEach(list, id: \.name) { p in
                let value = byMemory ? Double(p.footprintBytes) : p.cpuPercent
                HStack(spacing: 8) {
                    appIcon(p.appPath).frame(width: 16, height: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(p.name).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 6)
                            Text(byMemory ? bytes(p.footprintBytes) : String(format: "%.0f%%", p.cpuPercent))
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.system(size: 11))
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 1.5).fill((byMemory ? MonitorItem.memory : MonitorItem.cpu).color.opacity(0.7))
                                .frame(width: max(2, geo.size.width * CGFloat(value / top)), height: 3)
                        }
                        .frame(height: 3)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    /// The app's own icon, or a terminal symbol for command line tools.
    @ViewBuilder
    private func appIcon(_ path: String?) -> some View {
        if let path {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable()
        } else {
            Image(systemName: "terminal").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    // MARK: Network

    /// Download plus upload of every connection, one value per sample.
    private func networkCombinedHistory() -> [Double] {
        let series = monitor.networkHistory.values
        let length = series.map(\.count).max() ?? 0
        return (0..<length).map { i in
            series.reduce(0) { sum, h in
                let offset = length - h.count
                return i >= offset ? sum + h[i - offset].read + h[i - offset].write : sum
            }
        }
    }

    private var networkSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            header(.network)
            if monitor.network.isEmpty {
                Text("No active connection").foregroundStyle(.secondary)
            }
            ForEach(monitor.activeNetwork, id: \.bsdName) { connection in
                let samples = monitor.networkHistory[connection.bsdName] ?? []
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(connection.label).fontWeight(.semibold)
                        Spacer()
                        let r = rates(connection.downMBps, connection.upMBps)
                        Text("↓").foregroundStyle(Color(nsColor: .systemBlue)); Text("\(r.read) MB/s").monospacedDigit()
                        Text("↑").foregroundStyle(Color(nsColor: .systemOrange)); Text("\(r.write) MB/s").monospacedDigit()
                    }
                    .font(.caption)
                    HistoryChart(values: zoomed(samples.map(\.read), minSpan: 1, floor: 0, padding: 0.3),
                                 color: Color(nsColor: .systemBlue),
                                 scrub: scrub(samples.map(\.read)) { Monitor.speed($0) }).frame(height: 28)
                    HistoryChart(values: zoomed(samples.map(\.write), minSpan: 1, floor: 0, padding: 0.3),
                                 color: Color(nsColor: .systemOrange),
                                 scrub: scrub(samples.map(\.write)) { Monitor.speed($0) }).frame(height: 28)
                }
                .padding(8)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
            let hidden = monitor.network.count - monitor.activeNetwork.count
            if hidden > 0 {
                Text("\(hidden) idle connection\(hidden == 1 ? "" : "s") hidden").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Memory

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                header(.memory)
                Spacer()
                if let temp = shownTemp(monitor.thermal?.ramC) { Text(temp).monospacedDigit().foregroundStyle(.red) }
                if let ram = monitor.ram {
                    Text(pressureLabel(ram.pressure)).foregroundStyle(pressureColor(ram.pressure))
                }
            }
            if let ram = monitor.ram {
                Text("\(bytes(ram.usedBytes)) of \(bytes(ram.totalBytes)) used")
                HistoryChart(values: zoomed(monitor.ramHistory, minSpan: 0.03, floor: 0, padding: 0.01),
                             color: pressureColor(ram.pressure),
                             scrub: scrub(monitor.ramHistory.map { $0 * Double(ram.totalBytes) }) { bytes(UInt64(max(0, $0))) })
                    .frame(height: 40)
                MemoryBar(ram: ram).frame(height: 8)
                // How much memory macOS has squeezed, over the last minute: rising means pressure is building.
                HStack {
                    Text("Compressed over time").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(bytes(ram.compressedBytes)).font(.caption).monospacedDigit()
                }
                HistoryChart(values: zoomed(monitor.compressedHistory, minSpan: 100_000_000, floor: 0, padding: 20_000_000),
                             color: .purple,
                             scrub: scrub(monitor.compressedHistory) { bytes(UInt64(max(0, $0))) })
                    .frame(height: 24)
                VStack(spacing: 3) {
                    legend("App Memory", ram.appBytes, .blue)
                    legend("Wired", ram.wiredBytes, .orange)
                    legend("Compressed", ram.compressedBytes, .purple)
                    if ram.otherBytes > 0 { legend("Other", ram.otherBytes, .gray) }
                }
                .font(.caption)
                busiestApps(byMemory: true)
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
                                              scrub: ScrubReadout?, temp: String?,
                                              @ViewBuilder detail: () -> Detail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                header(item)
                Spacer()
                if let temp { Text(temp).monospacedDigit().foregroundStyle(.red) }
                Text(value.map { String(format: "%.0f%%", $0 * 100) } ?? "-").monospacedDigit()
            }
            HistoryChart(values: history, color: item.color, scrub: scrub).frame(height: 36)
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
                Text(average.map { percent($0) } ?? "-").font(.system(size: 12, design: .monospaced))
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: columns), spacing: 5) {
                ForEach(Array(cluster.cpus.enumerated()), id: \.element) { index, cpu in
                    MiniBox(title: "\(cpu)", value: loads[index].map { percent($0) } ?? "-",
                            history: zoomed(histories[index], minSpan: 0.07, floor: 0, padding: 0.05), color: color,
                            scrub: loadScrub(histories[index]))
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    /// macOS reports no per-GPU-core numbers without admin rights, so the boxes are the three loads
    /// it does report and the GPU's individual temperature sensors (sensors, not cores).
    private var gpuDetailView: some View {
        let d = monitor.gpuDetail
        let color = MonitorItem.gpu.color
        func box(_ title: String, _ value: Double?, _ history: [Double]) -> some View {
            MiniBox(title: title, value: value.map { percent($0) } ?? "-",
                    history: zoomed(history, minSpan: 0.07, floor: 0, padding: 0.05), color: color,
                    scrub: loadScrub(history))
        }
        return VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 3), spacing: 5) {
                box("Device", d?.device, monitor.gpuHistory)
                box("Renderer", d?.renderer, monitor.gpuRendererHistory)
                box("Tiler", d?.tiler, monitor.gpuTilerHistory)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 2), spacing: 5) {
                MiniBox(title: "Power", value: monitor.power?.gpuWatts.map { String(format: "%.2f W", $0) } ?? "-",
                        history: zoomed(monitor.gpuPowerHistory, minSpan: 0.5, floor: 0, padding: 0.1), color: .yellow,
                        scrub: scrub(monitor.gpuPowerHistory) { String(format: "%.2f W", $0) })
                MiniBox(title: "Memory", value: d?.memoryBytes.map { bytes(UInt64($0)) } ?? "-",
                        history: zoomed(monitor.gpuMemoryHistory, minSpan: 50_000_000, floor: 0, padding: 10_000_000),
                        color: .green,
                        scrub: scrub(monitor.gpuMemoryHistory) { bytes(UInt64(max(0, $0))) })
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
                                history: zoomed(i < monitor.gpuSensorHistory.count ? monitor.gpuSensorHistory[i] : [],
                                                minSpan: 4, padding: 1),
                                color: .red,
                                scrub: i < monitor.gpuSensorHistory.count
                                    ? ScrubReadout(values: monitor.gpuSensorHistory[i], secondsPerSample: sensorSeconds,
                                                   format: { settings.temperature($0, symbol: false) })
                                    : nil)
                    }
                }
            }
        }
        .padding(.top, 2)
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

    /// "Jonathan's AirPods Pro" -> "AirPods Pro": drop the owner's name so the card stays short.
    private func shortDeviceName(_ name: String) -> String {
        if let range = name.range(of: "’s ") ?? name.range(of: "'s ") { return String(name[range.upperBound...]) }
        return name
    }

    /// macOS's own thermal state; nothing is shown while it is "nominal".
    private func pressureText(_ state: ProcessInfo.ThermalState) -> String? {
        switch state {
        case .nominal: nil
        case .fair: "Warm"
        case .serious: "Throttling"
        case .critical: "Throttling hard"
        @unknown default: nil
        }
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

/// What the hover readout of a graph shows: the real value of every sample (the graph itself is
/// zoomed to its own range), how many seconds apart the samples are, and how to print a value.
struct ScrubReadout {
    let values: [Double]
    let secondsPerSample: Double
    let format: (Double) -> String
}

/// Filled history chart for a 0...1 value over the last 60 seconds.
struct HistoryChart: View {
    let values: [Double]
    let color: Color
    /// Real values behind `values`, for the hover readout. Nil (tiles) means no scrubbing.
    var scrub: ScrubReadout?

    @State private var hover: Int?

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
                if let scrub, let i = hover, i < scrub.values.count, i < points.count {
                    scrubMarker(scrub, index: i, at: points[i], size: geo.size)
                }
            }
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                guard let scrub else { return }
                switch phase {
                case .active(let location):
                    hover = scrubIndex(x: location.x, width: geo.size.width, count: scrub.values.count,
                                       slots: Monitor.historyLength)
                case .ended:
                    hover = nil
                }
            }
        }
    }

    /// A vertical line at the sample under the pointer, a dot on the graph and the real value.
    private func scrubMarker(_ scrub: ScrubReadout, index: Int, at point: CGPoint, size: CGSize) -> some View {
        let ago = scrub.values.count - 1 - index
        let text = "\(scrub.format(scrub.values[index])) · \(agoText(samplesAgo: ago, secondsPerSample: scrub.secondsPerSample))"
        return ZStack(alignment: point.x > size.width / 2 ? .topLeading : .topTrailing) {
            Rectangle().fill(Color.primary.opacity(0.55)).frame(width: 1, height: size.height)
                .position(x: point.x, y: size.height / 2)
            Circle().fill(color).overlay(Circle().stroke(Color.primary.opacity(0.8), lineWidth: 1))
                .frame(width: 5, height: 5).position(point)
            Text(text).font(.system(size: 9, weight: .medium, design: .monospaced))
                .padding(.horizontal, 3).padding(.vertical, 1)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 3))
                .padding(2)
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
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
