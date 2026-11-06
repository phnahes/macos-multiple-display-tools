import Foundation
import IOKit
import IOKit.hid

// Reads the MacBook lid angle from the hinge Hall sensor.
//
// The sensor is exposed as HID (usage page 0x20, usage 0x8A). Feature report 1
// carries the angle in degrees, little-endian, in its first two bytes.
// Prints the angle (0-180) and exits 0, or exits 1 when there is no sensor.

final class LidAngle {
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var device: IOHIDDevice?

    init() {
        let matching: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: 0x20,
            kIOHIDDeviceUsageKey as String: 0x8A,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              let first = devices.first,
              IOHIDDeviceOpen(first, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
        else { return }
        device = first
    }

    func read() -> Int? {
        guard let device else { return nil }
        var buffer = [UInt8](repeating: 0, count: 8)
        var length = 8
        let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &buffer, &length)
        guard result == kIOReturnSuccess, length >= 3 else { return nil }
        return Int(buffer[1]) | (Int(buffer[2]) << 8)
    }
}

if let angle = LidAngle().read() {
    print(angle)
} else {
    FileHandle.standardError.write(Data("lidangle: sensor unavailable\n".utf8))
    exit(1)
}
