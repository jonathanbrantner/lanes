import XCTest
import CPower
@testable import SystemMonitorCore

/// Sanity checks that run on any Mac, including GitHub's CI runners. They check that each
/// collector returns well-formed values, not specific numbers.
final class CollectorTests: XCTestCase {
    private let queue = DispatchQueue(label: "tests.sampler")

    // MARK: Memory

    func testRAMSnapshotIsConsistent() throws {
        let ram = RAMCollector(queue: queue)
        let s = try XCTUnwrap(ram.snapshot())
        XCTAssertEqual(s.totalBytes, ProcessInfo.processInfo.physicalMemory)
        XCTAssertGreaterThan(s.usedBytes, 0)
        XCTAssertLessThanOrEqual(s.usedBytes, s.totalBytes)
        // Activity Monitor's definition: total minus free minus file-backed cache, but never
        // below the sum of the parts (CI virtual machines under-report physical memory).
        let parts = s.appBytes + s.wiredBytes + s.compressedBytes
        XCTAssertEqual(s.usedBytes, max(s.totalBytes - s.freeBytes - s.fileBackedBytes, parts))
        XCTAssertGreaterThanOrEqual(s.usedBytes, parts)
        XCTAssertEqual(s.usedBytes, s.appBytes + s.wiredBytes + s.compressedBytes + s.otherBytes)
        XCTAssertTrue((0...1).contains(s.usedFraction))
        XCTAssertTrue([.normal, .warning, .critical].contains(s.pressure))
    }

    func testRAMSwapRefreshDoesNotCrash() {
        let ram = RAMCollector(queue: queue)
        ram.refreshSwap()
        XCTAssertNotNil(ram.snapshot())
    }

    // MARK: CPU

    func testCPUUsageNeedsTwoSamples() {
        let cpu = CPUCollector()
        XCTAssertNil(cpu.usage(), "first call only records a baseline")
        // Burn a little time so the tick counters move.
        var x = 0.0
        for i in 0..<200_000 { x += sin(Double(i)) }
        XCTAssertNotEqual(x, 12345)
        if let usage = cpu.usage() {
            XCTAssertTrue((0...1).contains(usage), "usage was \(usage)")
        }
    }

    // MARK: GPU

    func testGPUUtilizationIsFractionWhenAvailable() {
        if let gpu = GPUCollector().utilization() {
            XCTAssertTrue((0...1).contains(gpu), "gpu was \(gpu)")
        }
        // nil is fine: virtual machines and CI runners often have no accelerator entry.
    }

    // MARK: Drives

    func testDrivesReportNonNegativeSpeedsAndLabels() {
        let drives = DriveCollector(queue: queue)
        var first: [DriveRate] = []
        queue.sync { first = drives.rates(includeInternal: true) }
        XCTAssertTrue(first.isEmpty, "first call only records a baseline")

        Thread.sleep(forTimeInterval: 0.2)
        var second: [DriveRate] = []
        queue.sync { second = drives.rates(includeInternal: true) }
        for d in second {
            XCTAssertFalse(d.bsdName.isEmpty)
            XCTAssertFalse(d.label.isEmpty)
            XCTAssertGreaterThanOrEqual(d.readBytesPerSec, 0)
            XCTAssertGreaterThanOrEqual(d.writeBytesPerSec, 0)
            XCTAssertEqual(d.readMBps, d.readBytesPerSec / 1_000_000, accuracy: 0.0001)
        }
        // Every Mac has a boot drive, so with internals included there must be at least one.
        XCTAssertFalse(second.isEmpty, "expected at least the internal drive")
        XCTAssertTrue(second.contains { $0.isInternal })
    }

    func testExternalOnlyExcludesInternal() {
        let drives = DriveCollector(queue: queue)
        queue.sync { _ = drives.rates(includeInternal: false) }
        Thread.sleep(forTimeInterval: 0.2)
        var rates: [DriveRate] = []
        queue.sync { rates = drives.rates(includeInternal: false) }
        XCTAssertFalse(rates.contains { $0.isInternal })
    }

    // MARK: Power

    func testPowerValuesAreFiniteWhenAvailable() {
        let power = PowerCollector()
        guard let p = power.snapshot() else { return }   // nil on VMs without SMC/IOReport
        if let w = p.systemWatts { XCTAssertTrue(w.isFinite && w >= 0, "system watts \(w)") }
        if let g = p.gpuWatts { XCTAssertTrue(g.isFinite && g >= 0, "gpu watts \(g)") }
    }

    // MARK: Thermal

    func testThermalValuesAreSaneWhenAvailable() {
        let thermal = ThermalCollector(chip: ChipFamily.detect())
        guard let t = thermal.snapshot() else { return }   // nil on VMs without sensors
        for c in [t.cpuC, t.gpuC, t.ssdC].compactMap({ $0 }) {
            XCTAssertTrue(c > 0 && c < 130, "temperature \(c)")
        }
        for fan in t.fans {
            XCTAssertTrue(fan.rpm >= 0 && fan.maxRPM >= fan.minRPM, "fan \(fan)")
            XCTAssertTrue((0...1).contains(fan.fraction))
        }
    }

    func testChipFamilyParsesCPUNames() {
        XCTAssertEqual(ChipFamily.parse("Apple M1"), .m1)
        XCTAssertEqual(ChipFamily.parse("Apple M2 Max"), .m2)
        XCTAssertEqual(ChipFamily.parse("Apple M3 Ultra"), .m3)
        XCTAssertEqual(ChipFamily.parse("Apple M4 Pro"), .m4)
        XCTAssertEqual(ChipFamily.parse("Apple M5"), .m5)
        XCTAssertEqual(ChipFamily.parse("Apple M6"), .m6)
        XCTAssertEqual(ChipFamily.parse("Apple M12"), .other)       // unknown newer chip: scan
        XCTAssertEqual(ChipFamily.parse("Intel(R) Core(TM) i7"), .other)
    }

    func testDetectedChipFindsSensorsWhenSMCExists() {
        let t = ThermalCollector(chip: ChipFamily.detect())
        guard lanes_smc_open() == 1 else { return }   // VMs
        if ChipFamily.detect() != .other { XCTAssertTrue(t.foundCPUSensors, "no CPU sensor matched the detected chip") }
    }

    // MARK: Cores

    func testTopologyRanksClustersAndNamesThem() {
        // This Mac: cpu0-5 E, cpu6-7 P, cpu8-11 M, three perflevels.
        let types = Array(repeating: "E", count: 6) + ["P", "P"] + Array(repeating: "M", count: 4)
        let t = CPUTopology.build(types: types, names: ["Super", "Performance", "Efficiency"])
        XCTAssertEqual(t.coreCount, 12)
        XCTAssertEqual(t.clusters.map(\.kind), [.superCore, .performance, .efficiency])
        XCTAssertEqual(t.clusters[0].cpus, [6, 7])
        XCTAssertEqual(t.clusters[1].cpus, [8, 9, 10, 11])
        XCTAssertEqual(t.clusters[2].cpus, [0, 1, 2, 3, 4, 5])
    }

    func testTopologyTwoClassChip() {
        let t = CPUTopology.build(types: ["E", "E", "P", "P", "P", "P"], names: ["Performance", "Efficiency"])
        XCTAssertEqual(t.clusters.map(\.name), ["Performance", "Efficiency"])
        XCTAssertEqual(t.clusters[0].cpus, [2, 3, 4, 5])
    }

    func testDetectedTopologyMatchesCoreCount() {
        let t = CPUTopology.detect()
        XCTAssertEqual(t.coreCount, Sysctl.int("hw.ncpu"))
    }

    func testPerCoreUsageHasOneValuePerCore() {
        let cpu = CPUCollector()
        XCTAssertNil(cpu.perCoreUsage())
        Thread.sleep(forTimeInterval: 0.3)
        guard let usage = cpu.perCoreUsage() else { return XCTFail("no per-core data") }
        XCTAssertEqual(usage.count, CPUTopology.detect().coreCount)
        for u in usage { XCTAssertTrue((0...1).contains(u), "core load \(u)") }
    }

    func testGPUDetailsAreFractionsWhenAvailable() {
        guard let d = GPUCollector().details() else { return }   // nil on VMs
        for v in [d.device, d.renderer, d.tiler] { XCTAssertTrue((0...1).contains(v)) }
    }

    func testClusterTemperaturesAreSaneOrAbsent() {
        let thermal = ThermalCollector(chip: ChipFamily.detect())
        guard let t = thermal.snapshot(wanted: [.clusters, .gpuSensors]) else { return }   // nil on VMs
        for (_, c) in t.clusterC { XCTAssertTrue(c > 0 && c < 130, "cluster temp \(c)") }
        for c in t.gpuSensorsC { XCTAssertTrue(c > 0 && c < 130, "gpu sensor \(c)") }
    }
}
