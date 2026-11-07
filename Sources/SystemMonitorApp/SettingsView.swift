import SwiftUI
import SystemMonitorCore

/// One compact table: each item with a Menu bar checkbox and a Panel checkbox.
struct SettingsView: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var settings: Settings
    @ObservedObject var loginItem: LoginItem
    let back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { back() } label: { Label("Back", systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                Spacer()
                Text("Settings").font(.headline)
                Spacer()
                Color.clear.frame(width: 50, height: 1)
            }

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

            Divider()
            // Only relevant when Temperature is switched on somewhere.
            if settings.menuBarItems.contains(.temperature) || settings.panelItems.contains(.temperature) {
                Divider()
                HStack {
                    Text("Unit")
                    Spacer()
                    Picker("", selection: $settings.useFahrenheit) {
                        Text("°C").tag(false)
                        Text("°F").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                HStack {
                    Text("Chip")
                    Spacer()
                    Picker("", selection: $settings.chipOverride) {
                        Text("Automatic (\(ChipFamily.detect().shortTitle))").tag(ChipFamily?.none)
                        ForEach(ChipFamily.allCases) { chip in Text(chip.shortTitle).tag(ChipFamily?.some(chip)) }
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize()
                }
            }

            Divider()
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
        }
        .controlSize(.small)
    }
}
