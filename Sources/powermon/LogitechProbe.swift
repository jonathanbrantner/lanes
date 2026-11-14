import Foundation
import IOKit.hid

// powermon --logitech: tries to read the battery of Logitech mice and keyboards that talk through a
// Logitech USB receiver (Unifying, Bolt, Lightspeed) with Logitech's HID++ protocol.
// This is a test spike: it only prints what it finds.

private var received: [[UInt8]] = []

private let inputCallback: IOHIDReportCallback = { _, _, _, _, reportID, report, length in
    var bytes = [UInt8](UnsafeBufferPointer(start: report, count: length))
    if bytes.first.map({ UInt32($0) }) != reportID { bytes.insert(UInt8(truncatingIfNeeded: reportID), at: 0) }
    received.append(bytes)
}

func runLogitechProbe() {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x046D] as CFDictionary)
    IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    print("IOHIDManagerOpen:", String(format: "0x%08x", openResult), openResult == kIOReturnSuccess ? "ok" : "FAILED")
    guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { print("no devices"); return }

    func prop(_ d: IOHIDDevice, _ key: String) -> Any? { IOHIDDeviceGetProperty(d, key as CFString) }
    // HID++ interfaces: vendor usage pages 0xFF00 (receiver and USB devices) or 0xFF43 (BLE).
    let hidpp = devices.filter {
        let page = (prop($0, kIOHIDPrimaryUsagePageKey) as? Int) ?? 0
        return page == 0xFF00 || page == 0xFF43
    }
    for d in hidpp {
        print("HID++ interface:", prop(d, kIOHIDProductKey) ?? "?",
              "page", String(format: "0x%X", (prop(d, kIOHIDPrimaryUsagePageKey) as? Int) ?? 0),
              "usage", prop(d, kIOHIDPrimaryUsageKey) ?? "?",
              "transport", prop(d, kIOHIDTransportKey) ?? "?",
              "maxIn", prop(d, kIOHIDMaxInputReportSizeKey) ?? "?")
    }

    for device in hidpp {
        guard (prop(device, kIOHIDProductKey) as? String)?.contains("Receiver") == true else { continue }
        let maxIn = (prop(device, kIOHIDMaxInputReportSizeKey) as? Int) ?? 20
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(maxIn, 32))
        IOHIDDeviceRegisterInputReportCallback(device, buffer, max(maxIn, 32), inputCallback, nil)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        func send(_ device: IOHIDDevice, _ bytes: [UInt8]) -> [UInt8]? {
            received = []
            var report = bytes
            _ = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(bytes[0]), &report, report.count)
            CFRunLoopRunInMode(.defaultMode, 0.4, false)
            return received.first { $0.count > 4 && $0[1] == bytes[1] && $0[2] != 0x8f && $0[3] != 0x8f }
        }
        func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined(separator: " ") }

        for slot in 1...6 {
            // HID++ 2.0 ping first: slots with no device answer with an error (0x8f).
            guard let ping = send(device, [0x10, UInt8(slot), 0x00, 0x15, 0x00, 0x00, 0xAA]), ping.count > 4, ping[2] == 0x00 else { continue }
            print("slot \(slot): device answers HID++ \(ping[4]).\(ping[5])")
            // Which feature index is the battery? Try unified battery (0x1004), battery level (0x1000), voltage (0x1001).
            for (feature, name) in [(UInt16(0x1004), "unified battery"), (0x1000, "battery level"), (0x1001, "battery voltage")] {
                guard let r = send(device, [0x10, UInt8(slot), 0x00, 0x05, UInt8(feature >> 8), UInt8(feature & 0xFF), 0x00]),
                      r.count > 4, r[2] == 0x00, r[4] != 0 else { continue }
                let index = r[4]
                // Function 1 (getStatus) of unified battery; function 0 of battery level.
                let function: UInt8 = feature == 0x1004 ? 0x15 : 0x05
                if let status = send(device, [0x10, UInt8(slot), index, function, 0x00, 0x00, 0x00]), status.count > 6 {
                    print("  \(name) (feature index \(index)): \(hex(status))")
                    switch feature {
                    case 0x1004, 0x1000: print("  -> battery \(status[4])%")
                    default: print("  -> voltage \(Int(status[4]) << 8 | Int(status[5])) mV")
                    }
                    break
                }
            }
        }
    }
    print("done (if every send failed or nothing answered, macOS is not letting this app talk to the receiver)")
}
