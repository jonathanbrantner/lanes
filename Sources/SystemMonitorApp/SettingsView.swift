import SwiftUI
import SystemMonitorCore

/// Settings: one compact table (Menu bar and Panel checkboxes per item), a few switches, and a
/// "More" page for the chip choice and the definitions. The panel is an NSPopover that resizes to
/// its content, so rarely used material lives on its own page instead of an animated disclosure,
/// which made the popover jump on every frame.
struct SettingsView: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var settings: Settings
    @ObservedObject var loginItem: LoginItem
    let back: () -> Void

    @State private var showMore = false
    @State private var accuracy: [AccuracyLine]?
    @State private var accuracyFailed = false
    @State private var calibrationText = ""
    @State private var calibrationRefused = false

    var body: some View {
        Group {
            if showMore { morePage } else { mainPage }
        }
        .controlSize(.small)
    }

    // MARK: Main page

    private var mainPage: some View {
        VStack(alignment: .leading, spacing: 10) {
            header("Settings", action: back)

            // What to show: one row per item, two icon buttons (menu bar, panel).
            HStack(spacing: 4) {
                Spacer()
                Image(systemName: "menubar.rectangle").frame(width: 26).help("Show in the menu bar")
                Image(systemName: "square.grid.2x2").frame(width: 26).help("Show in the panel")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary).padding(.trailing, 10)
            SettingsGroup {
                ForEach(MonitorItem.allCases) { item in
                    SettingsRow(title: item.title, symbol: item.symbol, color: item.color) {
                        HStack(spacing: 4) {
                            IconToggle(symbol: "menubar.rectangle", label: "\(item.title) in the menu bar",
                                       isOn: settings.menuBarBinding(item))
                            IconToggle(symbol: "square.grid.2x2", label: "\(item.title) in the panel",
                                       isOn: settings.panelBinding(item))
                        }
                    }
                    if item != MonitorItem.allCases.last { Divider() }
                }
            }

            // Only useful with more than one external drive.
            if monitor.connectedExternalLabels.count > 1 {
                SectionHeader("Include these drives")
                SettingsGroup {
                    ForEach(monitor.connectedExternalLabels, id: \.self) { label in
                        SettingsRow(title: label) {
                            Toggle("", isOn: settings.driveBinding(label)).toggleStyle(.checkbox).labelsHidden()
                        }
                    }
                }
            }

            SectionHeader("Display")
            SettingsGroup {
                SettingsRow(title: "Temperatures") {
                    Picker("", selection: temperatureMode) {
                        Text("Off").tag(0)
                        Text("°C").tag(1)
                        Text("°F").tag(2)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                if monitor.logitechStatus.hasPrefix("open failed") {
                    Divider()
                    HStack {
                        Text("Mouse blocked: allow Lanes under Input Monitoring.").font(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button("Open") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
                        }
                    }
                    .padding(.bottom, 8)
                }
                Divider()
                SettingsRow(title: "Panel") {
                    Picker("", selection: $settings.panelList) {
                        Text("Grid").tag(false)
                        Text("Rows").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                Divider()
                SettingsRow(title: "Menu bar") {
                    Picker("", selection: $settings.menuBarIcons) {
                        Text("Names").tag(false)
                        Text("Icons").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }

            SectionHeader("General")
            SettingsGroup {
                SettingsRow(title: "Update every") {
                    Picker("", selection: $settings.updateInterval) {
                        ForEach(Settings.intervals, id: \.self) { Text("\(Int($0)) s").tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                Divider()
                SettingsRow(title: "Start at login") {
                    Toggle("", isOn: Binding(get: { loginItem.isOn }, set: { loginItem.set($0) }))
                        .toggleStyle(.checkbox).labelsHidden()
                }
                if loginItem.needsApproval {
                    Text("macOS needs your approval first.").font(.caption).foregroundStyle(.secondary)
                    Button("Open Login Items settings") { loginItem.openSystemSettings() }.padding(.bottom, 8)
                }
                if let error = loginItem.error {
                    Text(error).font(.caption).foregroundStyle(.red).padding(.bottom, 8)
                }
            }

            Button { showMore = true } label: {
                SettingsGroup {
                    SettingsRow(title: "Chip and definitions") {
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// One control for "show temperatures" and the unit: 0 = off, 1 = °C, 2 = °F.
    private var temperatureMode: Binding<Int> {
        Binding(
            get: { settings.showTemperatures ? (settings.useFahrenheit ? 2 : 1) : 0 },
            set: { mode in
                settings.showTemperatures = mode != 0
                if mode != 0 { settings.useFahrenheit = mode == 2 }
            })
    }

    // MARK: More page

    private var morePage: some View {
        VStack(alignment: .leading, spacing: 12) {
            header("Chip and definitions") { showMore = false }

            HStack {
                Text("Chip")
                Spacer()
                Picker("", selection: $settings.chipOverride) {
                    Text("Automatic (\(ChipFamily.detect().shortTitle))").tag(ChipFamily?.none)
                    ForEach(ChipFamily.allCases) { chip in Text(chip.shortTitle).tag(ChipFamily?.some(chip)) }
                }
                .pickerStyle(.menu).labelsHidden().fixedSize()
            }
            Text("Temperature sensors differ per chip. Lanes picks yours; change it only if temperatures are missing.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Divider()
            accuracySection
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                definition("App Memory", "Memory used by the apps you run and their helper processes.", .blue)
                definition("Wired", "Memory the system must keep in RAM (kernel, drivers). It can't be compressed or swapped out.", .orange)
                definition("Compressed", "Memory macOS squeezed to make room. It is unpacked when needed: slower than normal memory, faster than swap.", .purple)
                definition("Other", "Counted as used but not in the three above: purgeable, pre-loaded and kernel-reserved pages.", .gray)
                definition("Cached files", "File data kept in RAM for speed. Not counted as used; macOS frees it when apps need space.", nil)
                definition("Swap used", "Memory moved to the SSD because RAM is full. A lot of swap makes the Mac slower.", nil)
                definition("Pressure", "How hard macOS works to find free memory. \"Under pressure\" means heavy compressing or swapping.", nil)
                definition("CPU / GPU temp", "Average of that chip's sensors. Memory temperature only appears on chips that have a memory sensor.", .red)
                definition("Cores", "A core is one of your processor's workers. The CPU page shows how busy each one is, grouped as Efficiency cores (light tasks), Performance and Super cores (heavy tasks), with one temperature per group.", .indigo)
                definition("GPU sensors", "macOS gives no per-GPU-core numbers, so Renderer and Tiler load are shown, plus the GPU's separate temperature sensors (S1, S2 ...). Sensors are not cores.", .purple)
                definition("Avg temp", "Average of the CPU, GPU, memory (if available) and SSD temperatures.", .red)
                definition("Fan", "Current fan speed in revolutions per minute.", nil)
                definition("Network", "Download (blue) and upload (orange) per connection. Wi-Fi and Ethernet only; VPN and internal links are not counted twice.", .cyan)
                definition("Drive corner", "Free space on the drive. It turns into a red SMART warning if macOS reports the drive as failing.", nil)
                definition("Batteries", "Your Mac's battery (laptops) and connected Bluetooth devices that report one. The menu bar shows the lowest level.", .pink)
                definition("Warm / Throttling", "macOS's own heat level. Throttling means it is slowing the Mac down to cool off.", .orange)
            }
        }
    }

    // MARK: Check accuracy

    /// Compares Lanes' memory numbers with `vm_stat` on this Mac, so a Mac that looks off can be checked.
    private var accuracySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Accuracy").fontWeight(.semibold)
                Spacer()
                Button("Check now") { runAccuracyCheck() }
            }
            Text("Compares the memory numbers with macOS's own vm_stat. Activity Monitor uses the same counters.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text("Activity Monitor says").font(.caption)
                TextField("GB", text: $calibrationText).frame(width: 56).textFieldStyle(.roundedBorder)
                Button("Calibrate") { calibrate() }.disabled(Double(calibrationText.replacingOccurrences(of: ",", with: ".")) == nil)
                if settings.memoryCalibration != 0 { Button("Reset") { settings.memoryCalibration = 0 } }
            }
            if settings.memoryCalibration != 0 {
                Text(String(format: "Memory used is adjusted by %+.2f GB for this Mac.", Double(settings.memoryCalibration) / 1_073_741_824))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if calibrationRefused {
                Text("That is too far from Lanes' number to be a calibration.").font(.caption).foregroundStyle(.orange)
            }
            if let lines = accuracy {
                ForEach(lines, id: \.name) { line in
                    HStack {
                        Image(systemName: line.isOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(line.isOK ? .green : .orange)
                        Text(line.name)
                        Spacer()
                        Text(String(format: "%.2f vs %.2f GB  (%.2f%%)", line.lanesGB, line.referenceGB, line.differencePercent))
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            } else if accuracyFailed {
                Text("Could not run the check.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Makes Lanes' Memory used equal the number typed from Activity Monitor, for this Mac.
    private func calibrate() {
        guard let ram = monitor.ram, let gb = Double(calibrationText.replacingOccurrences(of: ",", with: ".")),
              let offset = ram.calibration(forActivityMonitorGB: gb) else { calibrationRefused = true; return }
        calibrationRefused = false
        settings.memoryCalibration = offset
        calibrationText = ""
    }

    private func runAccuracyCheck() {
        guard let ram = monitor.ram?.withCalibration(0) else { accuracyFailed = true; return }
        accuracyFailed = false
        DispatchQueue.global(qos: .userInitiated).async {
            let result = AccuracyCheck.run(snapshot: ram)
            DispatchQueue.main.async {
                accuracy = result
                accuracyFailed = result == nil
            }
        }
    }

    // MARK: Pieces

    private func header(_ title: String, action: @escaping () -> Void) -> some View {
        HStack {
            Button(action: action) { Label("Back", systemImage: "chevron.left") }
                .buttonStyle(.borderless)
            Spacer()
            Text(title).font(.headline)
            Spacer()
            Color.clear.frame(width: 50, height: 1)
        }
    }

    private func definition(_ title: String, _ text: String, _ color: Color?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Circle().fill(color ?? .clear).frame(width: 7, height: 7)
                Text(title).fontWeight(.semibold)
            }
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Settings building blocks

/// A rounded group of rows, like System Settings.
private struct SettingsGroup<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.horizontal, 10)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// One 30 pt row: optional icon, title, then the control at the right.
private struct SettingsRow<Control: View>: View {
    let title: String
    var symbol: String?
    var color: Color = .secondary
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 8) {
            if let symbol { Image(systemName: symbol).foregroundStyle(color).frame(width: 18) }
            Text(title)
            Spacer(minLength: 8)
            control
        }
        .frame(height: 30)
    }
}

private struct SectionHeader: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).tracking(0.5)
            .padding(.top, 2)
    }
}

/// A small icon button that is lit when on.
private struct IconToggle: View {
    let symbol: String
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            Image(systemName: symbol).font(.system(size: 12))
                .foregroundStyle(isOn ? Color.accentColor : Color.primary.opacity(0.35))
                .frame(width: 26, height: 22)
                .background(isOn ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "on" : "off")
    }
}
