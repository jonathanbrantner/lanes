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

    var body: some View {
        Group {
            if showMore { morePage } else { mainPage }
        }
        .controlSize(.small)
    }

    // MARK: Main page

    private var mainPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            header("Settings", action: back)

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                GridRow {
                    Color.clear.frame(height: 1)
                    Text("Menu bar").font(.caption).foregroundStyle(.secondary).gridColumnAlignment(.center)
                    Text("Panel").font(.caption).foregroundStyle(.secondary).gridColumnAlignment(.center)
                }
                ForEach(MonitorItem.allCases) { item in
                    GridRow {
                        HStack(spacing: 8) {
                            Image(systemName: item.symbol)
                                .foregroundStyle(item.color)
                                .frame(width: 18)
                            Text(item.title)
                        }
                        Toggle("", isOn: settings.menuBarBinding(item))
                        Toggle("", isOn: settings.panelBinding(item))
                    }
                }
            }
            .toggleStyle(.checkbox)
            .labelsHidden()

            // Only useful with more than one external drive.
            if monitor.connectedExternalLabels.count > 1 {
                Divider()
                Text("Include these drives").font(.caption).foregroundStyle(.secondary)
                ForEach(monitor.connectedExternalLabels, id: \.self) { label in
                    Toggle(label, isOn: settings.driveBinding(label)).toggleStyle(.checkbox)
                }
            }

            Divider()
            Picker("Update every", selection: $settings.updateInterval) {
                ForEach(Settings.intervals, id: \.self) { s in
                    Text(s == 1 ? "1 second" : "\(Int(s)) seconds").tag(s)
                }
            }
            .pickerStyle(.menu)

            HStack {
                Toggle("Show temperatures", isOn: $settings.showTemperatures).toggleStyle(.switch)
                Spacer()
                if usesTemperature {
                    Picker("", selection: $settings.useFahrenheit) {
                        Text("°C").tag(false)
                        Text("°F").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }
            Toggle("Core details", isOn: $settings.coreDetails).toggleStyle(.switch)
                .help("Adds a chevron to the CPU and GPU boxes to show every core")

            Toggle("Start at login", isOn: Binding(get: { loginItem.isOn }, set: { loginItem.set($0) }))
                .toggleStyle(.switch)
            if loginItem.needsApproval {
                Text("macOS needs your approval first.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open Login Items settings") { loginItem.openSystemSettings() }
            }
            if let error = loginItem.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            Divider()
            Button { showMore = true } label: {
                HStack {
                    Text("Chip and definitions")
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// The °C/°F choice matters whenever a temperature is shown anywhere.
    private var usesTemperature: Bool {
        settings.showTemperatures || settings.menuBarItems.contains(.thermal) || settings.panelItems.contains(.thermal)
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
            VStack(alignment: .leading, spacing: 8) {
                definition("App Memory", "Memory used by the apps you run and their helper processes.", .blue)
                definition("Wired", "Memory the system must keep in RAM (kernel, drivers). It can't be compressed or swapped out.", .orange)
                definition("Compressed", "Memory macOS squeezed to make room. It is unpacked when needed: slower than normal memory, faster than swap.", .purple)
                definition("Other", "Counted as used but not in the three above: purgeable, pre-loaded and kernel-reserved pages.", .gray)
                definition("Cached files", "File data kept in RAM for speed. Not counted as used; macOS frees it when apps need space.", nil)
                definition("Swap used", "Memory moved to the SSD because RAM is full. A lot of swap makes the Mac slower.", nil)
                definition("Pressure", "How hard macOS works to find free memory. \"Under pressure\" means heavy compressing or swapping.", nil)
                definition("CPU / GPU temp", "Average of that chip's sensors. Memory temperature only appears on chips that have a memory sensor.", .red)
                definition("Core details", "Load of each CPU core, grouped as Super, Performance and Efficiency cores, with one temperature per group. Open or close it with the chevron on the CPU and GPU boxes.", .indigo)
                definition("GPU sensors", "macOS gives no per-GPU-core numbers, so Renderer and Tiler load are shown, plus the GPU's separate temperature sensors (S1, S2 ...). Sensors are not cores.", .purple)
                definition("Avg temp", "Average of the CPU, GPU, memory (if available) and SSD temperatures.", .red)
                definition("Fan", "Current fan speed in revolutions per minute.", nil)
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
