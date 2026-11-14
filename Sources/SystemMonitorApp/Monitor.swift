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
    var coreUsage: [Double] = []        // per logical core, 0...1, only while the CPU page is open
    var gpuDetail: GPUDetails?
    // Short histories, kept only while the CPU or GPU page is open.
    var coreHistory: [[Double]] = []     // raw load per logical core, 0...1
    var gpuRendererHistory: [Double] = []
    var gpuTilerHistory: [Double] = []
    var gpuPowerHistory: [Double] = []     // watts
    var gpuMemoryHistory: [Double] = []    // bytes
    var gpuSensorHistory: [[Double]] = []   // one series per GPU temperature sensor, degrees C
    var allDrives: [DriveRate] = []
    var ramHistory: [Double] = []
    var compressedHistory: [Double] = []   // bytes, kept while Memory is shown
    var cpuHistory: [Double] = []
    var gpuHistory: [Double] = []
    var powerHistory: [Double] = []     // watts
    var driveHistory: [String: [DriveSample]] = [:]
    var network: [NetworkRate] = []
    var topByCPU: [ProcessUsage] = []      // only while the CPU or Memory page is open
    var topByMemory: [ProcessUsage] = []
    var thermalPressure: ProcessInfo.ThermalState = .nominal
    var volumes: [String: VolumeSpace] = [:]   // by volume name
    var smart: [String: SmartStatus] = [:]     // by BSD name (disk4)
    var networkHistory: [String: [DriveSample]] = [:]   // read = download, write = upload, MB/s
}

/// Runs the collectors on a low-priority queue (scheduled on efficiency cores) and publishes
/// a single `MonitorState` to the main thread each tick.
@MainActor
final class Monitor: ObservableObject {
    let settings = Settings()
    @Published private(set) var state = MonitorState()
    /// Which logical CPU is which kind of core. Read on first use (when a core view first opens), once.
    private(set) lazy var topology = CPUTopology.detect()
    /// Number of GPU cores, read once (nil if this Mac does not report it).
    private(set) lazy var gpuCoreCount: Int? = GPUCollector().coreCount

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
                          temperatures: settings.showTemperatures,
                          cpuCores: settings.cpuCoresVisible, gpuDetail: settings.gpuDetailVisible,
                          processes: settings.processesVisible)
    }

    // MARK: Convenience accessors used by the panel and icon

    var ram: RAMSnapshot? { state.ram }
    var cpu: Double? { state.cpu }
    var gpu: Double? { state.gpu }
    var power: PowerSnapshot? { state.power }
    var thermal: ThermalSnapshot? { state.thermal }
    var coreUsage: [Double] { state.coreUsage }
    var gpuDetail: GPUDetails? { state.gpuDetail }
    var coreHistory: [[Double]] { state.coreHistory }
    var gpuRendererHistory: [Double] { state.gpuRendererHistory }
    var gpuTilerHistory: [Double] { state.gpuTilerHistory }
    var gpuPowerHistory: [Double] { state.gpuPowerHistory }
    var gpuMemoryHistory: [Double] { state.gpuMemoryHistory }
    var gpuSensorHistory: [[Double]] { state.gpuSensorHistory }
    var ramHistory: [Double] { state.ramHistory }
    var compressedHistory: [Double] { state.compressedHistory }
    var cpuHistory: [Double] { state.cpuHistory }
    var gpuHistory: [Double] { state.gpuHistory }
    var powerHistory: [Double] { state.powerHistory }
    var driveHistory: [String: [DriveSample]] { state.driveHistory }
    var network: [NetworkRate] { state.network }
    var networkHistory: [String: [DriveSample]] { state.networkHistory }
    var topByCPU: [ProcessUsage] { state.topByCPU }
    var topByMemory: [ProcessUsage] { state.topByMemory }
    var thermalPressure: ProcessInfo.ThermalState { state.thermalPressure }
    var volumes: [String: VolumeSpace] { state.volumes }
    var smart: [String: SmartStatus] { state.smart }
    var networkDown: Double { state.network.reduce(0) { $0 + $1.downMBps } }
    var networkUp: Double { state.network.reduce(0) { $0 + $1.upMBps } }

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
    private lazy var networkCollector = NetworkCollector()
    private let diskSpace = DiskSpaceCollector()
    private let processCollector = ProcessCollector()
    private var processes = false
    private var thermal: ThermalCollector?   // created on first use, rebuilt when the chip choice changes
    private var chip = ChipFamily.detect()
    private var temperatures = true
    private var cpuCores = false
    private var gpuDetail = false
    private var coreSamples: [[Double]] = []
    private var detailRefresh: DispatchWorkItem?
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

    func configure(shown: Set<MonitorItem>, interval: TimeInterval, chip: ChipFamily, temperatures: Bool,
                   cpuCores: Bool, gpuDetail: Bool, processes: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            let coresOpened = cpuCores && !self.cpuCores
            let gpuOpened = gpuDetail && !self.gpuDetail
            self.shown = shown
            let processesOpened = processes && !self.processes
            if processes != self.processes { self.processCollector.reset(); self.processes = processes }
            if processesOpened { _ = self.processCollector.sample() }   // baseline for the first CPU numbers
            self.temperatures = temperatures
            self.cpuCores = cpuCores
            self.gpuDetail = gpuDetail
            // Opening a detail view: take the baseline now and show real numbers after 1 s,
            // instead of "Waiting for data" for a whole update interval.
            if coresOpened { self.cpu.resetPerCore(); _ = self.cpu.perCoreUsage() }
            if coresOpened || gpuOpened || processesOpened {
                self.detailRefresh?.cancel()   // pages opened quickly one after another: keep only the last
                let work = DispatchWorkItem { [weak self] in self?.refreshDetail() }
                self.detailRefresh = work
                self.queue.asyncAfter(deadline: .now() + 1, execute: work)
            }
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
            push(&state.compressedHistory, state.ram.map { Double($0.compressedBytes) })
        }
        if shown.contains(.cpu) {
            // Raw 1-tick sample feeds the chart; the displayed value is averaged over the
            // same 5 s window Activity Monitor uses, so the two numbers agree.
            if let sample = cpu.usage() { push(&state.cpuHistory, sample) }
            state.cpu = mean(state.cpuHistory.suffix(displayWindow))
        }
        sampleCores()
        if shown.contains(.gpu) {
            if gpuDetail {
                // One registry read serves both the overall value and the detail.
                state.gpuDetail = gpu.details()
                state.gpu = state.gpuDetail?.device
                push(&state.gpuRendererHistory, state.gpuDetail?.renderer)
                push(&state.gpuTilerHistory, state.gpuDetail?.tiler)
                push(&state.gpuPowerHistory, state.power?.gpuWatts)
                push(&state.gpuMemoryHistory, state.gpuDetail?.memoryBytes)
            } else {
                state.gpu = gpu.utilization()
                clearGPUDetail()
            }
            push(&state.gpuHistory, state.gpu)
        } else {
            clearGPUDetail()
        }
        if shown.contains(.power) || gpuDetail {   // the GPU page shows GPU power too
            if tickCount % 2 == 1 { state.power = power.snapshot() }   // heaviest read: every other tick
        }
        if shown.contains(.power) { push(&state.powerHistory, state.power?.systemWatts) }
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

        sampleNetwork()
        sampleDiskSpace()
        sampleProcesses()
        state.thermalPressure = ProcessInfo.processInfo.thermalState

        onSample?(state)
    }

    /// Busiest apps, every ~3 s, only while the CPU or Memory page is open.
    private func sampleProcesses() {
        guard processes else {
            state.topByCPU = []
            state.topByMemory = []
            return
        }
        let every = max(1, Int((3.0 / interval).rounded(.up)))
        guard (tickCount - 1) % every == 0 || state.topByCPU.isEmpty else { return }
        let all = processCollector.sample()
        state.topByCPU = Array(all.filter { $0.cpuPercent > 0 }.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(5))
        state.topByMemory = Array(all.sorted { $0.footprintBytes > $1.footprintBytes }.prefix(5))
    }

    /// Free space about every 30 s and health every 10 min, only while a drive item is shown.
    private func sampleDiskSpace() {
        guard shown.contains(.drives) || shown.contains(.disk) else {
            state.volumes = [:]
            state.smart = [:]
            return
        }
        let every = max(1, Int((30.0 / interval).rounded()))
        guard (tickCount - 1) % every == 0 || state.volumes.isEmpty else { return }
        state.volumes = Dictionary(diskSpace.volumes().map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var smart: [String: SmartStatus] = [:]
        for drive in state.allDrives { if let s = diskSpace.smart(bsdName: drive.bsdName) { smart[drive.bsdName] = s } }
        state.smart = smart
    }

    /// Download and upload per connection; averaged over the 5 s window like the drives.
    private func sampleNetwork() {
        guard shown.contains(.network) else {
            state.network = []
            state.networkHistory = [:]
            return
        }
        let rates = networkCollector.rates()
        var next: [String: [DriveSample]] = [:]
        for r in rates {
            var h = state.networkHistory[r.bsdName] ?? []
            h.append(DriveSample(read: r.downMBps, write: r.upMBps))
            if h.count > Monitor.historyLength { h.removeFirst(h.count - Monitor.historyLength) }
            next[r.bsdName] = h
        }
        state.networkHistory = next
        state.network = rates.map { r in
            let h = next[r.bsdName]?.suffix(displayWindow) ?? []
            return NetworkRate(bsdName: r.bsdName, label: r.label,
                               downBytesPerSec: (mean(h.map(\.read)) ?? r.downMBps) * 1_000_000,
                               upBytesPerSec: (mean(h.map(\.write)) ?? r.upMBps) * 1_000_000)
        }
    }

    private func clearGPUDetail() {
        state.gpuDetail = nil
        state.gpuRendererHistory = []
        state.gpuTilerHistory = []
        state.gpuPowerHistory = []
        state.gpuMemoryHistory = []
    }

    /// Light refresh used right after a detail view opens: cores, GPU detail and the thermal groups.
    private func refreshDetail() {
        sampleCores()
        sampleProcesses()
        state.gpuDetail = (gpuDetail && shown.contains(.gpu)) ? gpu.details() : nil
        state.thermal = nil   // forces a thermal read now, so the new groups appear with the cores
        sampleThermal()
        onSample?(state)
    }

    /// Per-core load, only while the CPU page is open; averaged over the same 5 s window as the
    /// overall CPU value. When closed, the baseline is dropped so reopening starts fresh.
    private func sampleCores() {
        guard cpuCores, shown.contains(.cpu) else {
            cpu.resetPerCore()
            state.coreUsage = []
            state.coreHistory = []
            coreSamples = []
            return
        }
        if let sample = cpu.perCoreUsage() {
            if state.coreHistory.count != sample.count { state.coreHistory = Array(repeating: [], count: sample.count) }
            for core in sample.indices { push(&state.coreHistory[core], sample[core]) }
            coreSamples.append(sample)
            if coreSamples.count > displayWindow { coreSamples.removeFirst(coreSamples.count - displayWindow) }
            state.coreUsage = sample.indices.map { core in
                coreSamples.reduce(0) { $0 + $1[core] } / Double(coreSamples.count)
            }
        }
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
            if cpuCores && shown.contains(.cpu) { wanted.insert(.clusters) }
            if gpuDetail && shown.contains(.gpu) { wanted.insert(.gpuSensors) }
        }
        if shown.contains(.thermal) { wanted.formUnion([.cpu, .gpu, .ram, .ssd, .fan]) }   // average + fan
        guard !wanted.isEmpty else {
            state.thermal = nil
            state.gpuSensorHistory = []
            return
        }
        let every = max(1, Int((3.0 / interval).rounded(.up)))
        guard (tickCount - 1) % every == 0 || state.thermal == nil else { return }
        if thermal == nil { thermal = ThermalCollector(chip: chip) }
        state.thermal = thermal?.snapshot(wanted: wanted)
        let sensors = state.thermal?.gpuSensorsC ?? []
        if sensors.isEmpty {
            state.gpuSensorHistory = []
        } else {
            if state.gpuSensorHistory.count != sensors.count {
                state.gpuSensorHistory = Array(repeating: [], count: sensors.count)
            }
            for i in sensors.indices { push(&state.gpuSensorHistory[i], sensors[i]) }
        }
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
