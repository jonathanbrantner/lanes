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
        /// Solid symbols read better at menu bar size than the outline ones the panel uses.
        func symbol(_ item: MonitorItem) -> String {
            switch item {
            case .memory: "memorychip"
            case .drives: "externaldrive.fill"
            case .disk: "internaldrive"
            case .power: "bolt.fill"
            case .thermal: "thermometer.medium"
            case .cpu: "cpu"
            case .gpu: "display"
            }
        }
        func cell(_ item: MonitorItem, label: String, value: String, short: String? = nil,
                  color: NSColor = .labelColor, samples: [String], shortSamples: [String]? = nil) -> IconCell {
            if icons {
                return IconCell(layout: .icon(symbol: symbol(item), symbolColor: item.nsColor, value: short ?? value),
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
        /// A drive: read on the first row, write on the second, in blue and orange. Same layout for the
        /// external drive and the internal disk; only the symbol (Icons) or name (Names) differs.
        func driveCell(_ item: MonitorItem, name: String, read: Double, write: Double, temp: (String, NSColor)?) -> IconCell {
            if icons {
                // Icons style: the temperature gets some air between it and the arrows.
                var built = IconCell(
                    layout: .twoRows(top: IconRow(symbol: "↓", symbolColor: .systemBlue, text: Self.speed(read, unit: "")),
                                     bottom: IconRow(symbol: "↑", symbolColor: .systemOrange, text: Self.speed(write, unit: ""))),
                    color: .labelColor, widthSamples: ["↓ 999.9"])
                built.leadingSymbol = (symbol(item), item.nsColor)
                if let temp { built.accent = ("  " + temp.0, temp.1) }
                return built
            }
            // Names style: the same shape as CPU and GPU: name above, then "↓0.0 ↑0.0 30°".
            var built = IconCell(
                layout: .labeled(label: name, value: "↓" + Self.speed(read, unit: "") + " ↑" + Self.speed(write, unit: "")),
                color: .labelColor, widthSamples: ["↓99.9 ↑99.9"], labelColor: item.nsColor)
            // The temperature goes on the name line, apart from the speeds: "DISK  31°".
            if let temp { built.labelAccent = (temp.0, temp.1) }
            return built
        }
        if on.contains(.drives) {
            if externalDrives.isEmpty {
                cells.append(cell(.drives, label: "SSD", value: "none", color: .secondaryLabelColor,
                                  samples: ["SSD", "88.8 GB"], shortSamples: ["none"]))
            } else {
                cells.append(driveCell(.drives, name: "SSD", read: externalRead, write: externalWrite, temp: nil))
            }
        }
        if on.contains(.disk), let d = internalDrive {
            let temp: (String, NSColor)? = settings.showTemperatures && settings.menuBarTemperatures
                ? thermal?.ssdC.map { (settings.temperature($0, symbol: false), .systemRed) } : nil
            cells.append(driveCell(.disk, name: "DISK", read: d.readMBps, write: d.writeMBps, temp: temp))
        }
        if on.contains(.power), let watts = power?.systemWatts {
            cells.append(cell(.power, label: "PWR", value: String(format: "%.1f W", watts),
                              short: String(format: "%.1f W", watts),
                              samples: ["PWR", "88.8 W"], shortSamples: ["88.8 W"]))
        }
        if on.contains(.thermal), let t = thermal, t.averageC != nil || !t.fans.isEmpty {
            let avg = t.averageC.map { settings.temperature($0, symbol: false) }
            let fan = t.fans.first.map { String(format: "%.0frpm", $0.rpm) }
            var built = cell(.thermal, label: "TEMP", value: fan.map { avg == nil ? $0 : " " + $0 } ?? "",
                             samples: ["TEMP", "212° 9999rpm"], shortSamples: ["99° 9999rpm"])
            if let avg { built.accent = (avg, .systemRed); built.accentFirst = true }
            cells.append(built)
        }
        for (item, label, load) in [(MonitorItem.cpu, "CPU", cpu), (.gpu, "GPU", gpu)] {
            guard on.contains(item), let load else { continue }
            let tempC = item == .cpu ? thermal?.cpuC : thermal?.gpuC
            let temp = settings.showTemperatures && settings.menuBarTemperatures
                ? tempC.map { " " + settings.temperature($0, symbol: false) } : nil
            let sample = temp == nil ? "100%" : "100% 212°"
            let percent = String(format: "%.0f%%", load * 100)
            var built = cell(item, label: label, value: percent, short: percent,
                             samples: [label, sample], shortSamples: ["99%"])
            if let temp { built.accent = (temp, .systemRed) }   // red temperature, like the panel
            cells.append(built)
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
