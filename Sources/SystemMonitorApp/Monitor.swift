import SwiftUI
import Combine
import SystemMonitorCore

struct DriveSample {
    var read: Double   // MB/s
    var write: Double  // MB/s
}

/// Everything the UI shows, produced once per tick. Immutable, so one publish per tick.
struct MonitorState {
    var ram: RAMSnapshot?
    var cpu: Double?
    var gpu: Double?
    var power: PowerSnapshot?
    var thermal: ThermalSnapshot?
    var allDrives: [DriveRate] = []
    var ramHistory: [Double] = []
    var cpuHistory: [Double] = []
    var gpuHistory: [Double] = []
    var powerHistory: [Double] = []     // watts
    var cpuTempHistory: [Double] = []   // °C, one point per thermal read (about every 3 s)
    var gpuTempHistory: [Double] = []
    var ramTempHistory: [Double] = []
    var driveHistory: [String: [DriveSample]] = [:]
}

/// Runs the collectors on a low-priority queue (scheduled on efficiency cores) and publishes
/// a single `MonitorState` to the main thread each tick.
@MainActor
final class Monitor: ObservableObject {
    let settings = Settings()
    @Published private(set) var state = MonitorState()

    nonisolated static let historyLength = 60

    private let sampler: Sampler?
    private var cancellables = Set<AnyCancellable>()

    /// Demo mode: fixed data, no sampling. Used to render README pictures.
    init(demo: MonitorState) {
        sampler = nil
        state = demo
    }

    init() {
        let sampler = Sampler()
        self.sampler = sampler
        sampler.onSample = { [weak self] state in
            DispatchQueue.main.async { self?.state = state }
        }
        applySettings()

        // Settings changes: re-render, and tell the sampler what to collect and how often.
        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                DispatchQueue.main.async { self?.applySettings() }   // after the new value is set
            }
            .store(in: &cancellables)
    }

    private func applySettings() {
        sampler?.configure(shown: settings.menuBarItems.union(settings.panelItems),
                          interval: settings.updateInterval, chip: settings.chip,
                          temperatures: settings.showTemperatures)
    }

    // MARK: Convenience accessors used by the panel and icon

    var ram: RAMSnapshot? { state.ram }
    var cpu: Double? { state.cpu }
    var gpu: Double? { state.gpu }
    var power: PowerSnapshot? { state.power }
    var thermal: ThermalSnapshot? { state.thermal }
    var ramHistory: [Double] { state.ramHistory }
    var cpuHistory: [Double] { state.cpuHistory }
    var gpuHistory: [Double] { state.gpuHistory }
    var powerHistory: [Double] { state.powerHistory }
    var cpuTempHistory: [Double] { state.cpuTempHistory }
    var gpuTempHistory: [Double] { state.gpuTempHistory }
    var ramTempHistory: [Double] { state.ramTempHistory }
    var driveHistory: [String: [DriveSample]] { state.driveHistory }

    /// External drives that are connected and not switched off in settings.
    var externalDrives: [DriveRate] {
        state.allDrives.filter { !$0.isInternal && !settings.hiddenDrives.contains($0.label) }
    }

    /// Every connected external drive, for the settings list.
    var connectedExternalLabels: [String] {
        state.allDrives.filter { !$0.isInternal }.map(\.label)
    }

    var internalDrive: DriveRate? { state.allDrives.first { $0.isInternal } }

    var externalRead: Double { externalDrives.reduce(0) { $0 + $1.readMBps } }
    var externalWrite: Double { externalDrives.reduce(0) { $0 + $1.writeMBps } }
}

/// Owns the collectors. Everything here runs on `queue`, never on the main thread.
private final class Sampler {
    var onSample: ((MonitorState) -> Void)?

    private let queue = DispatchQueue(label: "lanes.sampler", qos: .utility)
    private let ram: RAMCollector
    private let cpu = CPUCollector()
    private let gpu = GPUCollector()
    private let power = PowerCollector()
    private var thermal: ThermalCollector?   // created on first use, rebuilt when the chip choice changes
    private var chip = ChipFamily.detect()
    private var temperatures = true
    private let drives: DriveCollector
    private var timer: DispatchSourceTimer?

    private var shown: Set<MonitorItem> = []
    private var interval: TimeInterval = 1
    private var tickCount = 0
    private var state = MonitorState()

    init() {
        ram = RAMCollector(queue: queue)
        drives = DriveCollector(queue: queue)
    }

    func configure(shown: Set<MonitorItem>, interval: TimeInterval, chip: ChipFamily, temperatures: Bool) {
        queue.async {
            self.shown = shown
            self.temperatures = temperatures
            if chip != self.chip { self.chip = chip; self.thermal = nil; self.state.thermal = nil }
            let restart = interval != self.interval || self.timer == nil
            self.interval = interval
            if restart { self.startTimer() }
        }
    }

    private func startTimer() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        // Leeway lets macOS batch this wake-up with other work, which saves energy.
        t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(Int(interval * 250)))
        t.setEventHandler { [weak self] in self?.tick() }
        t.activate()
        timer = t
    }

    private func tick() {
        tickCount += 1

        if shown.contains(.memory) {
            if tickCount % 5 == 1 { ram.refreshSwap() }      // swap changes slowly
            state.ram = ram.snapshot()
            push(&state.ramHistory, state.ram?.usedFraction)
        }
        if shown.contains(.cpu) {
            // Raw 1-tick sample feeds the chart; the displayed value is averaged over the
            // same 5 s window Activity Monitor uses, so the two numbers agree.
            if let sample = cpu.usage() { push(&state.cpuHistory, sample) }
            state.cpu = mean(state.cpuHistory.suffix(displayWindow))
        }
        if shown.contains(.gpu) {
            state.gpu = gpu.utilization()
            push(&state.gpuHistory, state.gpu)
        }
        if shown.contains(.power) {
            if tickCount % 2 == 1 { state.power = power.snapshot() }   // heaviest read: every other tick
            push(&state.powerHistory, state.power?.systemWatts)
        }
        sampleThermal()

        let wantsDrives = shown.contains(.drives) || shown.contains(.disk)
        let rates = wantsDrives ? drives.rates(includeInternal: shown.contains(.disk)) : []
        state.allDrives = rates

        var next: [String: [DriveSample]] = [:]
        for r in rates {
            var h = state.driveHistory[r.bsdName] ?? []
            h.append(DriveSample(read: r.readMBps, write: r.writeMBps))
            if h.count > Monitor.historyLength { h.removeFirst(h.count - Monitor.historyLength) }
            next[r.bsdName] = h
        }
        state.driveHistory = next   // drops drives that were ejected

        // Displayed MB/s = mean over the 5 s window; the per-tick samples stay in the chart.
        state.allDrives = rates.map { r in
            let h = next[r.bsdName]?.suffix(displayWindow) ?? []
            return DriveRate(bsdName: r.bsdName, label: r.label, model: r.model, isInternal: r.isInternal,
                             readBytesPerSec: (mean(h.map(\.read)) ?? r.readMBps) * 1_000_000,
                             writeBytesPerSec: (mean(h.map(\.write)) ?? r.writeMBps) * 1_000_000)
        }

        onSample?(state)
    }

    /// Temperatures change slowly, so they are read about every 3 seconds whatever the update interval,
    /// and only the sensors whose section is on screen.
    private func sampleThermal() {
        var wanted: ThermalWanted = []
        if temperatures {
            if shown.contains(.cpu) { wanted.insert(.cpu) }
            if shown.contains(.gpu) { wanted.insert(.gpu) }
            if shown.contains(.memory) { wanted.insert(.ram) }
            if shown.contains(.disk) { wanted.insert(.ssd) }
            if shown.contains(.power) { wanted.formUnion([.cpu, .gpu, .ram, .ssd, .fan]) }   // average temperature and fan
        }
        guard !wanted.isEmpty else {
            state.thermal = nil
            state.cpuTempHistory = []; state.gpuTempHistory = []; state.ramTempHistory = []
            return
        }
        let every = max(1, Int((3.0 / interval).rounded(.up)))
        guard (tickCount - 1) % every == 0 || state.thermal == nil else { return }
        if thermal == nil { thermal = ThermalCollector(chip: chip) }
        state.thermal = thermal?.snapshot(wanted: wanted)
        push(&state.cpuTempHistory, state.thermal?.cpuC)
        push(&state.gpuTempHistory, state.thermal?.gpuC)
        push(&state.ramTempHistory, state.thermal?.ramC)
    }

    /// Number of ticks that make up Activity Monitor's default 5 second averaging window.
    private var displayWindow: Int { max(1, Int((5.0 / interval).rounded())) }

    private func mean<C: Collection>(_ values: C) -> Double? where C.Element == Double {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    private func push(_ history: inout [Double], _ value: Double?) {
        guard let value else { return }
        history.append(value)
        if history.count > Monitor.historyLength { history.removeFirst(history.count - Monitor.historyLength) }
    }
}
