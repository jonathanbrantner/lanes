import SwiftUI
import SystemMonitorCore

extension Monitor {
    /// What the menu bar icon shows right now, following the user's settings.
    /// Each item gets its own label colour; read is blue and write is orange, matching the charts.
    func iconCells() -> [IconCell] {
        var cells: [IconCell] = []
        let on = settings.menuBarItems

        if on.contains(.memory), let ram {
            let color: NSColor = switch ram.pressure {
            case .normal: .labelColor
            case .warning: .systemOrange
            case .critical: .systemRed
            }
            let gb = Double(ram.usedBytes) / 1_073_741_824
            cells.append(IconCell(layout: .labeled(label: "MEM", value: String(format: "%.1f GB", gb)),
                                  color: color, widthSamples: ["MEM", "88.8 GB"],
                                  labelColor: MonitorItem.memory.nsColor))
        }
        if on.contains(.drives) {
            if externalDrives.isEmpty {
                cells.append(IconCell(layout: .labeled(label: "SSD", value: "none"),
                                      color: .secondaryLabelColor, widthSamples: ["SSD", "88.8 GB"],
                                      labelColor: MonitorItem.drives.nsColor))
            } else {
                cells.append(IconCell(
                    layout: .twoRows(top: IconRow(symbol: "↓", symbolColor: .systemBlue, text: Self.speed(externalRead)),
                                     bottom: IconRow(symbol: "↑", symbolColor: .systemOrange, text: Self.speed(externalWrite))),
                    color: .labelColor, widthSamples: ["↓ 999.9 MB/s"]))
            }
        }
        if on.contains(.disk), let d = internalDrive {
            cells.append(IconCell(layout: .labeled(label: "DISK", value: Self.speed(d.readMBps + d.writeMBps)),
                                  color: .labelColor, widthSamples: ["DISK", "999.9 MB/s"],
                                  labelColor: MonitorItem.disk.nsColor))
        }
        if on.contains(.power), let watts = power?.systemWatts {
            cells.append(IconCell(layout: .labeled(label: "PWR", value: String(format: "%.1f W", watts)),
                                  color: .labelColor, widthSamples: ["PWR", "88.8 W"],
                                  labelColor: MonitorItem.power.nsColor))
        }
        if on.contains(.temperature), let c = thermal?.cpuC {
            cells.append(IconCell(layout: .labeled(label: "TEMP", value: String(format: "%.0f°C", c)),
                                  color: .labelColor, widthSamples: ["TEMP", "100°C"],
                                  labelColor: MonitorItem.temperature.nsColor))
        }
        if on.contains(.cpu), let cpu {
            cells.append(IconCell(layout: .labeled(label: "CPU", value: String(format: "%.0f%%", cpu * 100)),
                                  color: .labelColor, widthSamples: ["CPU", "100%"],
                                  labelColor: MonitorItem.cpu.nsColor))
        }
        if on.contains(.gpu), let gpu {
            cells.append(IconCell(layout: .labeled(label: "GPU", value: String(format: "%.0f%%", gpu * 100)),
                                  color: .labelColor, widthSamples: ["GPU", "100%"],
                                  labelColor: MonitorItem.gpu.nsColor))
        }
        return cells
    }

    static func speed(_ mbps: Double) -> String {
        if mbps >= 1000 { return String(format: "%.2f GB/s", mbps / 1000) }
        if mbps >= 10 { return String(format: "%.0f MB/s", mbps) }
        return String(format: "%.1f MB/s", mbps)
    }
}
