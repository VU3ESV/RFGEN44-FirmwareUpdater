import Foundation
import IOKit.hid

/// Talks to a PICkit 3 directly over HID, outside MPLAB, for two jobs:
/// - asking which firmware it runs, with the read-only GETVERSIONS_MPLAB (0x41) query that MPLAB and
///   Microchip's "PICkit 3 Programmer App" send when they connect;
/// - putting a PICkit 3 that was left in the Programmer App's scripting firmware back into MPLAB mode,
///   the same way that app's Tools ▸ Revert to MPLAB mode does.
///
/// ipecmd reports "Connection Failed" for a PICkit 3 running scripting firmware.
/// Every call blocks for a few seconds, so run it off the main thread.
enum PICkit3Probe {
    enum Firmware: Equatable {
        /// PICkit 3 Programmer App scripting OS. MPLAB cannot use it.
        case scripting(version: String)
        /// MPLAB bootloader: MPLAB downloads its firmware on the next connect.
        case mplabBootloader
        /// MPLAB firmware loaded; `suite` is the Firmware Suite Version MPLAB prints, e.g. "01.56.09".
        case mplab(suite: String?)
        case noReply
        case unrecognised
    }

    enum SwitchResult: Equatable {
        case switched
        case notNeeded
        case bootloaderMissing
        case failed(String)
    }

    private static let scriptingMagicKey = 0x336B50 // "Pk3"
    private static let mplabBootloaderType: UInt8 = 0x99
    private static let getVersions: UInt8 = 0x41
    private static let testBootloader: UInt8 = 0x2A
    private static let switchToBootloader: UInt8 = 0x24

    static func identify() -> Firmware {
        guard let session = HIDSession() else { return .noReply }
        defer { session.close() }
        return firmware(of: session)
    }

    /// Restarts a PICkit 3 running scripting firmware into its MPLAB bootloader. Checks that the
    /// bootloader exists before switching and that the PICkit comes back in it afterwards.
    static func switchToMPLABMode() -> SwitchResult {
        guard let session = HIDSession() else { return .failed("The PICkit 3 could not be opened.") }
        guard case .scripting = firmware(of: session) else {
            session.close()
            return .notNeeded
        }
        guard let test = session.query(testBootloader, mplabFraming: false), test.count >= 3,
              test[0] == testBootloader, test[1] == 0
        else {
            session.close()
            return .failed("The PICkit 3 did not answer the bootloader check.")
        }
        guard test[2] == 0x99 else {
            session.close()
            return .bootloaderMissing
        }
        let reply = session.query(switchToBootloader, mplabFraming: false)
        session.close()
        guard let reply, reply.count >= 3, reply[0] == switchToBootloader, reply[1] == 0, reply[2] == 0x99 else {
            return .failed("The PICkit 3 refused to switch to its bootloader.")
        }

        // It drops off USB and comes back in the bootloader.
        Thread.sleep(forTimeInterval: 2)
        for _ in 0..<30 {
            if let again = HIDSession() {
                let mode = firmware(of: again)
                again.close()
                if mode == .mplabBootloader { return .switched }
                if mode != .noReply { return .failed("The PICkit 3 restarted but is not in its MPLAB bootloader.") }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return .failed("The PICkit 3 did not come back on USB. Unplug it and plug it back in.")
    }

    private static func firmware(of session: HIDSession) -> Firmware {
        guard let r = session.query(getVersions, mplabFraming: true), r.count >= 36 else { return .noReply }
        let magic = Int(r[30]) | Int(r[31]) << 8 | Int(r[32]) << 16
        if magic == scriptingMagicKey { return .scripting(version: "\(r[33]).\(r[34]).\(r[35])") }
        guard r[0] == getVersions, r[1] == 0, r[4] == 0, r[5] == 0 else { return .unrecognised }
        if r[10] == mplabBootloaderType { return .mplabBootloader }
        // Bytes 25–27 hold the Firmware Suite Version as BCD-style hex, e.g. 01 56 09.
        let suite = r[25] | r[26] | r[27] == 0 ? nil : String(format: "%02X.%02X.%02X", r[25], r[26], r[27])
        return .mplab(suite: suite)
    }
}

/// One open PICkit 3 (04D8:900A) HID device with a blocking request/reply helper.
private final class HIDSession {
    private final class Reply { var bytes: [UInt8]? }

    private let device: IOHIDDevice
    private let reply = Reply()
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)

    init?() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x04D8, kIOHIDProductIDKey: 0x900A] as CFDictionary)
        guard let device = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>)?.first,
              IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
        else {
            buffer.deallocate()
            return nil
        }
        self.device = device
        let callback: IOHIDReportCallback = { context, _, _, _, _, report, length in
            Unmanaged<Reply>.fromOpaque(context!).takeUnretainedValue().bytes = Array(UnsafeBufferPointer(start: report, count: length))
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, callback, Unmanaged.passUnretained(reply).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }

    deinit { buffer.deallocate() }

    func close() {
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    /// Sends a 64-byte report: command, 0x00, 0xAD padding; MPLAB framing also puts the command
    /// length (2) little-endian in bytes 60–63. Returns the reply report, if one arrives within 3 s.
    func query(_ command: UInt8, mplabFraming: Bool) -> [UInt8]? {
        reply.bytes = nil
        var report = [UInt8](repeating: 0xAD, count: 64)
        report[0] = command
        report[1] = 0x00
        if mplabFraming {
            report[60] = 2
            report[61] = 0
            report[62] = 0
            report[63] = 0
        }
        guard IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, report, report.count) == kIOReturnSuccess else {
            return nil
        }
        CFRunLoopRunInMode(.defaultMode, 3.0, false)
        return reply.bytes
    }
}
