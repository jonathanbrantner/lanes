import SwiftUI
import SystemMonitorCore

extension Monitor {
    /// What the menu bar icon shows right now, following the user's settings.
    /// Two styles share the same colours: Names (tiny coloured label above the value) and Icons
    /// (coloured symbol, then the value with its unit dropped, since the symbol says what it is).
    /// Read is blue and write is orange, matching the charts. Whatever is switched on is shown, in a
    /// fixed order, nothing is merged.
    func iconCells() -> [IconCell] {
        var cells: [IconCell] = []
        let on = settings.menuBarItems
        let icons = settings.menuBarIcons

        /// One cell in the chosen style. `value` is the full text, `short` the Icons-style text,
        /// `samples` / `shortSamples` the widest strings for a steady width.
        func cell(_ item: MonitorItem, label: String, value: String, short: String? = nil,
                  color: NSColor = .labelColor, samples: [String], shortSamples: [String]? = nil) -> IconCell {
            if icons {
                return IconCell(layout: .icon(symbol: item.symbol, symbolColor: item.nsColor, value: short ?? value),
                                color: color, widthSamples: shortSamples ?? Array(samples.dropFirst()))
            }
            return IconCell(layout: .labeled(label: label, value: value), color: color, widthSamples: samples,
                            labelColor: item.nsColor)
        }

        if on.contains(.memory), let ram {
            let color: NSColor = switch ram.pressure {
            case .normal: .labelColor
            case .warning: .systemOrange
            case .critical: .systemRed
            }
            let gb = Double(ram.usedBytes) / 1_073_741_824
            cells.append(cell(.memory, label: "MEM", value: String(format: "%.1f GB", gb),
                              short: String(format: "%.1f", gb), color: color,
                              samples: ["MEM", "88.8 GB"], shortSamples: ["88.8"]))
        }
        if on.contains(.drives) {
            if externalDrives.isEmpty {
                cells.append(cell(.drives, label: "SSD", value: "none", color: .secondaryLabelColor,
                                  samples: ["SSD", "88.8 GB"], shortSamples: ["none"]))
            } else {
                // Arrows already say what it is, so both styles share the two-row layout.
                cells.append(IconCell(
                    layout: .twoRows(top: IconRow(symbol: "↓", symbolColor: .systemBlue, text: Self.speed(externalRead, unit: icons ? "" : nil)),
                                     bottom: IconRow(symbol: "↑", symbolColor: .systemOrange, text: Self.speed(externalWrite, unit: icons ? "" : nil))),
                    color: .labelColor, widthSamples: [icons ? "↓ 999.9" : "↓ 999.9 MB/s"]))
            }
        }
        if on.contains(.disk), let d = internalDrive {
            cells.append(cell(.disk, label: "DISK", value: Self.speed(d.readMBps + d.writeMBps),
                              short: Self.speed(d.readMBps + d.writeMBps, unit: ""),
                              samples: ["DISK", "999.9 MB/s"], shortSamples: ["999.9"]))
        }
        if on.contains(.power), let watts = power?.systemWatts {
            cells.append(cell(.power, label: "PWR", value: String(format: "%.1f W", watts),
                              short: String(format: "%.1f W", watts),
                              samples: ["PWR", "88.8 W"], shortSamples: ["88.8 W"]))
        }
        if on.contains(.thermal), let t = thermal, t.averageC != nil || !t.fans.isEmpty {
            var parts: [String] = []
            if let avg = t.averageC { parts.append(settings.temperature(avg, symbol: false)) }
            if let fan = t.fans.first { parts.append(String(format: "%.0frpm", fan.rpm)) }
            cells.append(cell(.thermal, label: "TEMP", value: parts.joined(separator: " "),
                              samples: ["TEMP", "212° 9999rpm"], shortSamples: ["212° 9999rpm"]))
        }
        for (item, label, load) in [(MonitorItem.cpu, "CPU", cpu), (.gpu, "GPU", gpu)] {
            guard on.contains(item), let load else { continue }
            let tempC = item == .cpu ? thermal?.cpuC : thermal?.gpuC
            let temp = settings.showTemperatures ? tempC.map { " " + settings.temperature($0, symbol: false) } : nil
            let sample = temp == nil ? "100%" : "100% 212°"
            cells.append(cell(item, label: label, value: String(format: "%.0f%%", load * 100) + (temp ?? ""),
                              samples: [label, sample], shortSamples: [sample]))
        }
        return cells
    }

    /// "0.7 MB/s"; pass `unit: ""` for the number alone (Icons style). GB/s keeps its unit, since
    /// 1.20 and 412 would otherwise be ambiguous.
    static func speed(_ mbps: Double, unit: String? = nil) -> String {
        let suffix = mbps >= 1000 ? " GB/s" : (unit ?? " MB/s")
        if mbps >= 1000 { return String(format: "%.2f", mbps / 1000) + suffix }
        if mbps >= 10 { return String(format: "%.0f", mbps) + suffix }
        return String(format: "%.1f", mbps) + suffix
    }
}
