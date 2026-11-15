import AppKit
import SwiftUI
import Combine

// Plain AppKit entry point: no SwiftUI App scene, so no stray windows and SwiftUI is only
// loaded when the panel is opened.
// Hidden mode for the README: render the UI with demo data to PNG files and exit.
if let dir = ProcessInfo.processInfo.environment["LANES_SCREENSHOT_DIR"] {
    MainActor.assumeIsolated { ScreenshotMode.run(outputDir: dir) }
    exit(0)
}

let appDelegate = MainActor.assumeIsolated { AppDelegate() }
NSApplication.shared.delegate = appDelegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)

/// Owns the menu bar item and the popover that hangs from it. The popover's SwiftUI content
/// is created when it opens and thrown away when it closes, so a closed Lanes keeps no view
/// tree in memory and does no layout work. Only the small icon is updated.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let monitor = Monitor()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only: no Dock icon.
        NSApplication.shared.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.imagePosition = .imageOnly
        }
        statusItem = item
        updateIcon()

        popover.behavior = .transient   // closes when you click elsewhere
        popover.delegate = self

        // One state publish per tick -> one icon check. The icon image is cached, so this is
        // a string comparison unless a number actually changed.
        monitor.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)
        monitor.settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)

        // Testing aid: LANES_OPEN=main|cpu|memory opens the panel on that page at launch, so its CPU
        // cost can be measured without clicking.
        if let page = ProcessInfo.processInfo.environment["LANES_OPEN"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self else { return }
                switch page {
                case "cpu": self.monitor.settings.openDetail = .cpu
                case "memory": self.monitor.settings.openDetail = .memory
                case "gpu": self.monitor.settings.openDetail = .gpu
                default: break
                }
                self.togglePopover(nil)
            }
        }
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let image = IconRenderer.image(cells: monitor.iconCells())
        if button.image !== image { button.image = image }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            let host = NSHostingController(rootView: PanelView(monitor: monitor))
            host.sizingOptions = [.preferredContentSize]   // popover follows the content's size
            popover.contentViewController = host
            NSApplication.shared.activate(ignoringOtherApps: true)
            // Anchor on the drawn icon itself, centred inside the button, so the arrow points
            // at the middle of the icon whatever padding AppKit adds around it.
            let iconWidth = button.image?.size.width ?? button.bounds.width
            let anchor = NSRect(x: (button.bounds.width - iconWidth) / 2, y: 0,
                                width: iconWidth, height: button.bounds.height)
            if ProcessInfo.processInfo.environment["LANES_DEBUG"] != nil {
                FileHandle.standardError.write(
                    "button \(button.bounds) image \(button.image?.size ?? .zero) anchor \(anchor) alignmentRect \(button.alignmentRectInsets)\n"
                        .data(using: .utf8)!)
            }
            popover.show(relativeTo: anchor, of: button, preferredEdge: .minY)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil   // frees the SwiftUI view tree
        monitor.settings.openDetail = nil     // next time the panel opens on the tiles; stops core sampling
    }
}
