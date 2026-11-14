import AppKit
import SwiftUI
import SystemMonitorCore

/// Renders the menu bar icon and the panel with made-up demo data to PNG files, at 2x.
/// Run with `LANES_SCREENSHOT_DIR=docs` (see scripts/make-screenshots.sh). Nothing here reads
/// the real system, so the pictures never contain the machine's own data.
@MainActor
enum ScreenshotMode {
    static func run(outputDir: String) {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

        let monitor = Monitor(demo: demoState())
        monitor.settings.menuBarItems = [.memory, .drives]
        monitor.settings.panelItems = [.memory, .drives, .disk, .power, .thermal, .cpu, .gpu, .network, .devices]
        monitor.settings.hiddenDrives = []

        // Menu bar strip: the icon on a dark menu-bar-like background.
        let icon = IconRenderer.image(cells: monitor.iconCells())
        let strip = NSImage(size: NSSize(width: icon.size.width + 32, height: 24), flipped: false) { rect in
            NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.13, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            icon.draw(at: NSPoint(x: 16, y: 1), from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        write(strip, scale: 2, to: "\(outputDir)/menubar.png")

        // Panels: the real SwiftUI views on a rounded dark card, like the popover.
        renderPanel(PanelView(monitor: monitor), to: "\(outputDir)/panel.png")
        monitor.settings.openDetail = .cpu
        renderPanel(PanelView(monitor: monitor), to: "\(outputDir)/panel-cpu.png")
        monitor.settings.openDetail = .gpu
        renderPanel(PanelView(monitor: monitor), to: "\(outputDir)/panel-gpu.png")
        monitor.settings.openDetail = .thermal
        renderPanel(PanelView(monitor: monitor), to: "\(outputDir)/panel-sensors.png")
        monitor.settings.openDetail = .devices
        renderPanel(PanelView(monitor: monitor), to: "\(outputDir)/panel-batteries.png")
        monitor.settings.openDetail = .network
        renderPanel(PanelView(monitor: monitor), to: "\(outputDir)/panel-network.png")
    }

    private static func renderPanel(_ panel: PanelView, to path: String) {
        let card = panel
            .background(Color(nsColor: NSColor(calibratedRed: 0.13, green: 0.13, blue: 0.16, alpha: 1)))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(12)
        let host = NSHostingView(rootView: card)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        write(view: host, scale: 2, to: path)
    }

    private static func demoState() -> MonitorState {
        func curve(_ n: Int, _ f: (Double) -> Double) -> [Double] { (0..<n).map { f(Double($0) / Double(n - 1)) } }
        let gb = 1_073_741_824.0
        var s = MonitorState()
        s.ram = RAMSnapshot(appBytes: UInt64(9.9 * gb), wiredBytes: UInt64(2.7 * gb),
                            compressedBytes: UInt64(3.5 * gb), cachedBytes: UInt64(6.0 * gb),
                            totalBytes: UInt64(24 * gb), swapUsedBytes: UInt64(0.7 * gb), pressure: .normal,
                            freeBytes: UInt64(1.5 * gb), fileBackedBytes: UInt64(5.6 * gb))
        s.ramHistory = curve(60) { 0.62 + 0.05 * sin($0 * 9) + 0.03 * $0 }
        s.cpu = 0.14
        s.cpuHistory = curve(60) { 0.10 + 0.08 * abs(sin($0 * 14)) + ($0 > 0.7 ? 0.25 * sin(($0 - 0.7) * 10) : 0) }
        s.avgTempHistory = curve(60) { 40 + 3 * sin($0 * 7) + 2 * $0 }
        s.gpu = 0.06
        s.gpuHistory = curve(60) { 0.02 + 0.05 * max(0, sin($0 * 20)) }
        s.power = PowerSnapshot(systemWatts: 9.8, gpuWatts: 0.12)
        s.powerHistory = curve(60) { 7 + 2 * abs(sin($0 * 6)) + ($0 > 0.75 ? 9 * sin(($0 - 0.75) * 12) : 0) }
        s.thermal = ThermalSnapshot(cpuC: 46, gpuC: 42, ramC: 39, ssdC: 38,
                                    fans: [FanReading(rpm: 1800, minRPM: 1000, maxRPM: 4900)],
                                    clusterC: [.superCore: 52, .performance: 47, .efficiency: 41],
                                    gpuSensorsC: [41, 42, 42, 41, 43, 42, 41, 42, 42, 43, 41, 42])
        s.coreUsage = [0.22, 0.18, 0.12, 0.09, 0.07, 0.05, 0.31, 0.24, 0.06, 0.04, 0.03, 0.02]
        s.gpuDetail = GPUDetails(device: 0.06, renderer: 0.05, tiler: 0.02, memoryBytes: 236_000_000)
        s.coreHistory = s.coreUsage.enumerated().map { core, load in
            curve(60) { max(0, min(1, load * (0.5 + 1.0 * abs(sin($0 * (4 + Double(core)) + Double(core)))))) }
        }
        s.gpuPowerHistory = curve(60) { 0.05 + 0.12 * max(0, sin($0 * 15)) }
        s.gpuMemoryHistory = curve(60) { 200_000_000 + 40_000_000 * sin($0 * 5) }
        s.gpuRendererHistory = curve(60) { 0.02 + 0.05 * max(0, sin($0 * 17)) }
        s.gpuTilerHistory = curve(60) { 0.01 + 0.03 * max(0, sin($0 * 13 + 1)) }
        s.gpuSensorHistory = (0..<12).map { i in curve(30) { 41 + 1.5 * sin($0 * 6 + Double(i)) + 0.8 * Double(i % 3) } }
        s.network = [NetworkRate(bsdName: "en0", label: "Wi-Fi", downBytesPerSec: 3.2e6, upBytesPerSec: 0.4e6)]
        s.networkHistory = ["en0": (0..<60).map { i in let t = Double(i) / 59; return DriveSample(read: 2 + 3 * abs(sin(t * 8)), write: 0.2 + 0.5 * abs(sin(t * 5))) }]
        s.compressedHistory = curve(60) { 3.3e9 + 0.2e9 * sin($0 * 6) }
        s.volumes = ["Work SSD": VolumeSpace(name: "Work SSD", totalBytes: 1_000_000_000_000, freeBytes: 412_000_000_000, isInternal: false),
                     "Macintosh HD": VolumeSpace(name: "Macintosh HD", totalBytes: 500_000_000_000, freeBytes: 210_000_000_000, isInternal: true)]
        s.smart = ["disk4": .verified, "disk0": .verified]
        s.topByCPU = [ProcessUsage(pid: 1, name: "Safari", cpuPercent: 14, footprintBytes: 900_000_000),
                      ProcessUsage(pid: 2, name: "Xcode", cpuPercent: 9, footprintBytes: 2_100_000_000),
                      ProcessUsage(pid: 3, name: "WindowServer", cpuPercent: 6, footprintBytes: 400_000_000)]
        s.topByMemory = [ProcessUsage(pid: 2, name: "Xcode", cpuPercent: 9, footprintBytes: 2_100_000_000),
                         ProcessUsage(pid: 1, name: "Safari", cpuPercent: 14, footprintBytes: 900_000_000),
                         ProcessUsage(pid: 4, name: "Slack", cpuPercent: 1, footprintBytes: 620_000_000)]
        s.deviceBatteries = [DeviceBattery(name: "AirPods Pro", parts: [("Left", 86), ("Right", 84), ("Case", 19)]),
                             DeviceBattery(name: "Keyboard", parts: [("", 62)])]
        s.sensors = [SensorReading(kind: .temperature, name: "SSD (NAND)", value: 38),
                     SensorReading(kind: .temperature, name: "Chip die sensor 1", value: 44),
                     SensorReading(kind: .temperature, name: "Chip die sensor 2", value: 46),
                     SensorReading(kind: .fan, name: "Fan speed", value: 1800),
                     SensorReading(kind: .fan, name: "Fan maximum", value: 4900),
                     SensorReading(kind: .power, name: "System power", value: 9.8),
                     SensorReading(kind: .power, name: "Processor package power", value: 2.7),
                     SensorReading(kind: .voltage, name: "VD0R", value: 0.78),
                     SensorReading(kind: .current, name: "ID0R", value: 0.35)]
        let ssd = DriveRate(bsdName: "disk4", label: "Work SSD", model: "Demo SSD", isInternal: false,
                            readBytesPerSec: 412e6, writeBytesPerSec: 186e6)
        let internalDisk = DriveRate(bsdName: "disk0", label: "Internal SSD", model: "Demo", isInternal: true,
                                     readBytesPerSec: 3.1e6, writeBytesPerSec: 1.4e6)
        s.allDrives = [internalDisk, ssd]
        s.driveHistory = [
            "disk4": (0..<60).map { i in
                let t = Double(i) / 59
                let copy = t > 0.45 ? 1.0 : 0.0
                return DriveSample(read: copy * (380 + 60 * sin(t * 25)) + 3 * abs(sin(t * 40)),
                                   write: copy * (170 + 40 * sin(t * 18 + 1)) + 2 * abs(sin(t * 33)))
            },
            "disk0": (0..<60).map { i in
                let t = Double(i) / 59
                return DriveSample(read: 2 + 6 * max(0, sin(t * 30)), write: 1 + 4 * max(0, sin(t * 22 + 2)))
            },
        ]
        return s
    }

    private static func write(view: NSView, scale: CGFloat, to path: String) {
        let scaled = NSBitmapImageRep(bitmapDataPlanes: nil,
                                      pixelsWide: Int(view.bounds.width * scale),
                                      pixelsHigh: Int(view.bounds.height * scale),
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        scaled.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: scaled)
        try? scaled.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    private static func write(_ image: NSImage, scale: CGFloat, to path: String) {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: Int(image.size.width * scale),
                                   pixelsHigh: Int(image.size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
