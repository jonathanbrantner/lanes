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

    // MARK: Graph zoom

    func testZoomedFlatSeriesStaysFlatAndCentred() {
        let z = zoomed([0.68, 0.68, 0.68], minSpan: 0.04, floor: 0)
        XCTAssertEqual(z.count, 3)
        for v in z { XCTAssertEqual(v, 0.5, accuracy: 0.001) }
    }

    func testZoomedUsesTheRecentRangeAndKeepsOrder() {
        let z = zoomed([0.02, 0.05, 0.40, 0.05], minSpan: 0.15, floor: 0, headroom: 0)
        XCTAssertEqual(z.min()!, 0, accuracy: 0.001)
        XCTAssertEqual(z.max()!, 1, accuracy: 0.001)
        XCTAssertTrue(z[2] > z[1] && z[1] > z[0])
    }

    func testZoomedRespectsFloorAndMinimumSpan() {
        // A tiny wobble is not blown up: 0.01 to 0.03 with a 0.15 minimum span stays in the lower part.
        let z = zoomed([0.01, 0.03], minSpan: 0.15, floor: 0)
        XCTAssertEqual(z[0], 0.01 / 0.15, accuracy: 0.001)
        XCTAssertTrue(z[1] < 0.3)
    }

    func testZoomedEmpty() {
        XCTAssertEqual(zoomed([], minSpan: 1), [])
    }

    func testZoomedPaddingGivesRoomAroundTheData() {
        // A GPU that never goes above 2%: with 5 points of padding the line is not squashed into the
        // bottom of a 0...100% scale, and not pinned to the top either.
        let z = zoomed([0, 0.01, 0.02, 0.01], minSpan: 0.07, floor: 0, padding: 0.05)
        XCTAssertEqual(z.min()!, 0, accuracy: 0.001)               // floor holds
        XCTAssertTrue(z.max()! > 0.2 && z.max()! < 0.5, "max \(z.max()!)")
    }

    func testZoomedPaddingBelowAndAboveWithoutFloor() {
        let z = zoomed([40, 44], minSpan: 2, padding: 1)             // range 39...45
        XCTAssertEqual(z[0], 1.0 / 6, accuracy: 0.001)
        XCTAssertEqual(z[1], 5.0 / 6, accuracy: 0.001)
    }

    func testZoomedLeavesTenPercentHeadroomSoSpikesDoNotTouchTheTop() {
        let z = zoomed([0.1, 0.1, 0.4, 0.1], minSpan: 0.05)          // range 0.1...0.4, headroom 0.03
        XCTAssertTrue(z.max()! < 0.95, "max \(z.max()!)")           // not pinned to the top
        XCTAssertTrue(z.min()! > 0.05, "min \(z.min()!)")           // nor to the bottom
        XCTAssertEqual(z.max()!, (0.4 - 0.07) / 0.36, accuracy: 0.001)   // 0.917: 8% below the top
    }

    func testScrubIndexMapsPointerToRightAlignedSamples() {
        // 60 slots over 590 pt: 10 pt per step. Three samples cover only the right edge.
        XCTAssertEqual(scrubIndex(x: 590, width: 590, count: 3, slots: 60), 2)
        XCTAssertEqual(scrubIndex(x: 570, width: 590, count: 3, slots: 60), 0)
        XCTAssertNil(scrubIndex(x: 100, width: 590, count: 3, slots: 60))
        XCTAssertEqual(scrubIndex(x: 0, width: 590, count: 60, slots: 60), 0)
        XCTAssertNil(scrubIndex(x: 10, width: 590, count: 0, slots: 60))
    }

    func testAgoText() {
        XCTAssertEqual(agoText(samplesAgo: 0, secondsPerSample: 5), "now")
        XCTAssertEqual(agoText(samplesAgo: 9, secondsPerSample: 5), "45 s ago")
        XCTAssertEqual(agoText(samplesAgo: 13, secondsPerSample: 5), "1 min 5 s ago")
        XCTAssertEqual(agoText(samplesAgo: 12, secondsPerSample: 5), "1 min ago")
    }

    func testGPUCoreCountIsNilOrPositive() {
        if let n = GPUCollector().coreCount { XCTAssertGreaterThan(n, 0) }
    }

    func testAccuracyReferenceParsesVMStat() {
        let text = """
        Mach Virtual Memory Statistics: (page size of 16384 bytes)
        Pages free:                                    42171.
        Pages purgeable:                               45017.
        Pages wired down:                             160046.
        File-backed pages:                            556237.
        Anonymous pages:                              708063.
        Pages occupied by compressor:                  68833.
        """
        let total = 25_769_803_776.0
        let ref = AccuracyCheck.reference(vmStat: text, totalBytes: total)
        XCTAssertNotNil(ref)
        let gb = 1_073_741_824.0
        XCTAssertEqual(ref!.wired, 160046 * 16384 / gb, accuracy: 0.0001)
        XCTAssertEqual(ref!.used, (total - 42171 * 16384 - 556237 * 16384) / gb, accuracy: 0.0001)
        XCTAssertNil(AccuracyCheck.reference(vmStat: "garbage", totalBytes: total))
    }

    func testNetworkDeltaHandlesCounterWrap() {
        XCTAssertEqual(NetworkCollector.delta(old: 100, new: 400), 300)
        XCTAssertEqual(NetworkCollector.delta(old: UInt32.max - 9, new: 5), 15)
    }

    func testNetworkOnlyCountsPhysicalInterfaces() {
        XCTAssertTrue(NetworkCollector.isPhysical("en0"))
        XCTAssertTrue(NetworkCollector.isPhysical("en12"))
        for name in ["lo0", "utun3", "awdl0", "bridge0", "llw0", "en0x", "en"] {
            XCTAssertFalse(NetworkCollector.isPhysical(name), name)
        }
    }

    func testSmartStatusParsing() {
        func plist(_ status: String) -> Data {
            "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>SMARTStatus</key><string>\(status)</string></dict></plist>".data(using: .utf8)!
        }
        XCTAssertEqual(DiskSpaceCollector.parseSmart(plist: plist("Verified")), .verified)
        XCTAssertEqual(DiskSpaceCollector.parseSmart(plist: plist("Failing")), .failing)
        XCTAssertNil(DiskSpaceCollector.parseSmart(plist: plist("Not Supported")))
        XCTAssertNil(DiskSpaceCollector.parseSmart(plist: Data()))
    }

    func testVolumeSpaceText() {
        let v = VolumeSpace(name: "X", totalBytes: 1_000_000_000_000, freeBytes: 412_000_000_000, isInternal: true)
        XCTAssertEqual(v.usedFraction, 0.588, accuracy: 0.001)
        XCTAssertTrue(v.freeText.hasSuffix("free"))
        XCTAssertFalse(DiskSpaceCollector().volumes().isEmpty)
    }

    func testProcessCPUPercent() {
        XCTAssertEqual(ProcessCollector.cpuPercent(oldNs: 0, newNs: 500_000_000, seconds: 1), 50, accuracy: 0.001)
        XCTAssertEqual(ProcessCollector.cpuPercent(oldNs: 0, newNs: 2_000_000_000, seconds: 1), 200, accuracy: 0.001)
        XCTAssertEqual(ProcessCollector.cpuPercent(oldNs: 10, newNs: 5, seconds: 1), 0)
    }

    func testProcessSweepFindsThisProcess() {
        let collector = ProcessCollector()
        _ = collector.sample()
        let mine = collector.sample().first { $0.pid == getpid() }
        XCTAssertNotNil(mine)
        XCTAssertGreaterThan(mine?.footprintBytes ?? 0, 0)
    }

    func testSensorKindsAndNames() {
        XCTAssertEqual(SensorsCollector.kind(forKey: "Tp0g"), .temperature)
        XCTAssertEqual(SensorsCollector.kind(forKey: "PSTR"), .power)
        XCTAssertEqual(SensorsCollector.kind(forKey: "F0Ac"), .fan)
        XCTAssertNil(SensorsCollector.kind(forKey: "FNum"))
        XCTAssertNil(SensorsCollector.kind(forKey: "MSLD"))
        XCTAssertEqual(SensorsCollector.friendlyName(forHID: "NAND CH0"), "SSD (NAND)")
        XCTAssertEqual(SensorsCollector.friendlyName(forHID: "PMU tdie4"), "Chip die 4")
        XCTAssertEqual(SensorsCollector.friendlyName(forHID: "PMU2 tdev3"), "Chip 2 device 3")
        XCTAssertTrue(SensorsCollector.isPlausible(40, kind: .temperature))
        XCTAssertFalse(SensorsCollector.isPlausible(400, kind: .temperature))
        XCTAssertFalse(SensorsCollector.isPlausible(.nan, kind: .power))
    }

    func testSensorsReadFindsReadings() {
        let readings = SensorsCollector().read()
        XCTAssertFalse(readings.isEmpty)
        XCTAssertTrue(readings.contains { $0.kind == .temperature })
    }

    func testBluetoothBatteryParsing() {
        let json = """
        {"SPBluetoothDataType":[{"device_connected":[
          {"AirPods":{"device_batteryLevelCase":"19%","device_batteryLevelLeft":"86%","device_batteryLevelRight":"80%"}},
          {"Keyboard":{}},
          {"Mouse":{"device_batteryLevelMain":"54%"}}]}]}
        """.data(using: .utf8)!
        let devices = DeviceBatteries.parseBluetooth(json: json)
        XCTAssertEqual(devices.map(\.name), ["AirPods", "Mouse"])
        XCTAssertEqual(devices[0].lowestPercent, 80)   // the case (19%) does not count
        XCTAssertEqual(devices[1].parts.first?.percent, 54)
        XCTAssertTrue(DeviceBatteries.parseBluetooth(json: Data()).isEmpty)
        XCTAssertEqual(DeviceBatteries.percent("86%"), 86)
    }

    func testLaptopBatteryIsNilOrSane() {
        if let b = DeviceBatteries.laptop() { XCTAssertTrue((0...100).contains(b.percent)) }
    }

    func testMemoryCalibration() {
        let gb = UInt64(1_073_741_824)
        let snap = RAMSnapshot(appBytes: 8 * gb, wiredBytes: 2 * gb, compressedBytes: gb, cachedBytes: 5 * gb,
                               totalBytes: 24 * gb, swapUsedBytes: 0, pressure: .normal,
                               freeBytes: 6 * gb, fileBackedBytes: 5 * gb)
        XCTAssertEqual(snap.usedBytes, 13 * gb)
        let offset = snap.calibration(forActivityMonitorGB: 12.5)
        XCTAssertEqual(offset, -Int64(gb) / 2)
        XCTAssertEqual(snap.withCalibration(offset!).usedBytes, 12 * gb + gb / 2)
        XCTAssertEqual(snap.withCalibration(offset!).withCalibration(0).usedBytes, 13 * gb)
        XCTAssertNil(snap.calibration(forActivityMonitorGB: 40))   // not a calibration, a typo
        XCTAssertNil(snap.calibration(forActivityMonitorGB: 0))
    }

    func testLogitechNameShortening() {
        XCTAssertEqual(LogitechReceiver.shortName("G502 LIGHTSPEED Wireless Gaming Mouse"), "G502 LIGHTSPEED Mouse")
        XCTAssertEqual(LogitechReceiver.shortName("MX Keys Mini"), "MX Keys Mini")
        XCTAssertEqual(LogitechReceiver.shortName("Wireless"), "Wireless")
    }

    func testProcessDisplayNames() {
        let safari = ProcessCollector.displayName(path: "/Applications/Safari.app/Contents/MacOS/Safari", rawName: "Safari")
        XCTAssertEqual(safari.name, "Safari")
        XCTAssertEqual(safari.appPath, "/Applications/Safari.app")
        let helper = ProcessCollector.displayName(
            path: "/Applications/Google Chrome.app/Contents/Frameworks/X.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)",
            rawName: "Google Chrome H")
        XCTAssertEqual(helper.name, "Google Chrome")
        let xpc = ProcessCollector.displayName(
            path: "/System/Library/Frameworks/Virtualization.framework/X/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine",
            rawName: "com.apple.Virtualization.Virtua")
        XCTAssertEqual(xpc.name, "Virtualization.VirtualMachine")
        XCTAssertNil(xpc.appPath)
        XCTAssertEqual(ProcessCollector.displayName(path: "/Users/x/.local/share/claude/versions/2.1.325", rawName: "2.1.325").name, "claude")
        XCTAssertEqual(ProcessCollector.displayName(path: "/usr/local/bin/node", rawName: "node").name, "node")
    }

    func testProcessCombineAddsHelpers() {
        let list = [ProcessUsage(pid: 1, name: "Safari", cpuPercent: 5, footprintBytes: 100),
                    ProcessUsage(pid: 2, name: "Safari", cpuPercent: 3, footprintBytes: 50, appPath: "/Applications/Safari.app"),
                    ProcessUsage(pid: 3, name: "node", cpuPercent: 1, footprintBytes: 10)]
        let combined = ProcessCollector.combine(list).sorted { $0.name < $1.name }
        XCTAssertEqual(combined.count, 2)
        XCTAssertEqual(combined[0].cpuPercent, 8)
        XCTAssertEqual(combined[0].footprintBytes, 150)
        XCTAssertEqual(combined[0].appPath, "/Applications/Safari.app")
    }

    func testHardwarePortParsing() {
        let text = """
        Hardware Port: Ethernet
        Device: en6
        Ethernet Address: aa:bb

        Hardware Port: Wi-Fi
        Device: en0
        Ethernet Address: cc:dd
        """
        let map = NetworkCollector.parseHardwarePorts(text)
        XCTAssertEqual(map["en0"], "Wi-Fi")
        XCTAssertEqual(map["en6"], "Ethernet")
    }

    func testSensorSummary() {
        let r = [SensorReading(kind: .temperature, name: "Chip die 1", value: 30),
                 SensorReading(kind: .temperature, name: "Chip 2 die 4", value: 40),
                 SensorReading(kind: .temperature, name: "SSD (NAND)", value: 35),
                 SensorReading(kind: .fan, name: "Chip die fan", value: 999)]
        let s = SensorsCollector.summary(r, kind: .temperature, namePrefix: "die")
        XCTAssertEqual(s?.count, 2)
        XCTAssertEqual(s?.average, 35)
        XCTAssertEqual(s?.maximum, 40)
        XCTAssertNil(SensorsCollector.summary(r, kind: .power, namePrefix: "die"))
    }
}
