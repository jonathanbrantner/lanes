import Foundation
import IOKit.hid

/// Battery of Logitech mice and keyboards that talk through a Logitech USB receiver (Unifying, Bolt,
/// Lightspeed), read with Logitech's HID++ 2.0 protocol over the receiver's own interface. macOS does
/// not list these batteries anywhere else. Opt-in (Settings > Display), because it opens the receiver.
/// Each read pings the six pairing slots and asks a present device for its battery; it takes about a
/// second, so call it from a background queue, never from the sampler tick.
public enum LogitechReceiver {
    /// Pure and testable: battery percent from a cell voltage in millivolts (single cell Li-ion curve).
    public static func percent(fromMillivolts mv: Int) -> Int {
        let curve: [(mv: Int, pct: Int)] = [(4186, 100), (4067, 90), (3989, 80), (3922, 70), (3859, 60),
                                            (3811, 50), (3778, 40), (3754, 30), (3729, 20), (3691, 10),
                                            (3615, 5), (3500, 0)]
        if mv >= curve[0].mv { return 100 }
        if mv <= curve[curve.count - 1].mv { return 0 }
        for i in 1..<curve.count where mv >= curve[i].mv {
            let hi = curve[i - 1], lo = curve[i]
            return lo.pct + (hi.pct - lo.pct) * (mv - lo.mv) / (hi.mv - lo.mv)
        }
        return 0
    }

    /// What the last read did, for diagnosing a missing device: "open ok, 1 receiver, 1 device".
    public nonisolated(unsafe) static var lastStatus = "not read yet"

    private final class Inbox { var reports: [[UInt8]] = [] }

    public static func batteries() -> [DeviceBattery] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x046D] as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        let opened = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard opened == kIOReturnSuccess else {
            lastStatus = String(format: "open failed 0x%08x (macOS is probably blocking input access)", opened)
            return []
        }
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            lastStatus = "open ok, no Logitech devices"
            return []
        }
        var receivers = 0
        defer {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }

        var out: [DeviceBattery] = []
        for device in devices {
            let page = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int
            let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String
            guard page == 0xFF00, product?.contains("Receiver") == true else { continue }

            receivers += 1
            let inbox = Inbox()
            let size = max((IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int) ?? 20, 32)
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            defer { buffer.deallocate() }
            let context = Unmanaged.passUnretained(inbox).toOpaque()
            IOHIDDeviceRegisterInputReportCallback(device, buffer, size, { context, _, _, _, id, report, length in
                guard let context else { return }
                var bytes = [UInt8](UnsafeBufferPointer(start: report, count: length))
                if bytes.first.map({ UInt32($0) }) != id { bytes.insert(UInt8(truncatingIfNeeded: id), at: 0) }
                Unmanaged<Inbox>.fromOpaque(context).takeUnretainedValue().reports.append(bytes)
            }, context)
            IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

            /// Sends a 7 byte HID++ request and returns the matching answer (nil for errors and silence).
            func ask(_ slot: UInt8, _ index: UInt8, _ function: UInt8, _ params: [UInt8] = []) -> [UInt8]? {
                inbox.reports = []
                var report: [UInt8] = [0x10, slot, index, (function << 4) | 0x05] + params
                while report.count < 7 { report.append(0) }
                _ = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x10, &report, report.count)
                CFRunLoopRunInMode(.defaultMode, 0.25, false)
                if ProcessInfo.processInfo.environment["LANES_DEBUG_HID"] != nil {
                    print("ask slot \(slot) idx \(index) fn \(function): got \(inbox.reports.map { $0.prefix(8).map { String(format: "%02x", $0) }.joined() })")
                }
                return inbox.reports.first { $0.count > 6 && $0[1] == slot && $0[2] == index && $0[3] == report[3] }
            }

            for slot in UInt8(1)...UInt8(6) {
                // An empty slot answers with an error, a present device answers the ping.
                // (One retry: the receiver can be slow to answer the first request after it was idle.)
                guard ask(slot, 0x00, 0x01, [0x00, 0x00, 0xAA]) != nil || ask(slot, 0x00, 0x01, [0x00, 0x00, 0xAA]) != nil
                else { continue }
                // Feature indexes: ask the root feature where each feature lives.
                func feature(_ id: UInt16) -> UInt8? {
                    guard let r = ask(slot, 0x00, 0x00, [UInt8(id >> 8), UInt8(id & 0xFF)]), r[4] != 0 else { return nil }
                    return r[4]
                }
                var percent: Int?
                if let unified = feature(0x1004), let r = ask(slot, unified, 0x01) { percent = Int(r[4]) }
                else if let level = feature(0x1000), let r = ask(slot, level, 0x00) { percent = Int(r[4]) }
                else if let voltage = feature(0x1001), let r = ask(slot, voltage, 0x00) {
                    percent = Self.percent(fromMillivolts: Int(r[4]) << 8 | Int(r[5]))
                }
                guard let percent else { continue }
                var name = "Logitech device"
                if let nameFeature = feature(0x0005), let count = ask(slot, nameFeature, 0x00), count[4] > 0 {
                    var text = [UInt8]()
                    var offset: UInt8 = 0
                    while offset < count[4], let chunk = ask(slot, nameFeature, 0x01, [offset]) {
                        let part = Array(chunk[4...].prefix { $0 != 0 })
                        if part.isEmpty { break }
                        text += part
                        offset = UInt8(min(255, text.count))
                    }
                    if !text.isEmpty { name = String(decoding: text, as: UTF8.self) }
                }
                out.append(DeviceBattery(name: name, parts: [("", min(100, max(0, percent)))]))
            }
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        }
        lastStatus = "open ok, \(receivers) receiver\(receivers == 1 ? "" : "s"), \(out.count) device\(out.count == 1 ? "" : "s") answered"
        return out
    }
}
