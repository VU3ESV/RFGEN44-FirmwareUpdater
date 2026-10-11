import Foundation

public enum IPEStage: Int, Sendable, CaseIterable, Comparable {
    case connecting, erasing, programming, verifying, reading

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var title: String {
        switch self {
        case .connecting: "Connect"
        case .erasing: "Erase"
        case .programming: "Program"
        case .verifying: "Verify"
        case .reading: "Read back"
        }
    }
}

public enum LineSeverity: Sendable, Equatable {
    case info, success, warning, error
}

/// Follows ipecmd's console output to track progress, pick out results and explain failures.
///
/// A typical PICkit 3 run (MPLAB X v6.20) prints "Connecting to MPLAB PICkit 3…", "Target device
/// PIC16F1459 found.", "Erasing…", "Programming…", "Programming/Verify complete", "Program Succeeded.",
/// "PK3 Verify Report … Verify Succeeded." and finally "Operation Succeeded".
public struct IPEOutputParser: Sendable {
    public private(set) var stage: IPEStage?
    public private(set) var detectedTargetDevice: String?
    public private(set) var deviceID: String?
    public private(set) var deviceRevision: String?
    /// DEVID from "Target Device ID (0x3027) is an Invalid Device ID" or "… does not match expected …".
    public private(set) var reportedDeviceID: UInt16?
    /// MPLAB is loading its firmware onto the programmer ("Now Downloading new Firmware…", "Downloading RS/AP…").
    public private(set) var loadingToolFirmware = false
    /// From "Firmware Suite Version.....01.56.09"; the last one printed is what the tool ends up running.
    public private(set) var toolFirmwareVersion: String?
    public private(set) var errorLines: [String] = []
    public private(set) var programSucceeded = false
    public private(set) var verifySucceeded = false
    public private(set) var operationSucceeded = false
    /// A line that means the run failed, even if ipecmd's exit code says otherwise
    /// (it has been seen to exit 0 after "Connection Failed").
    public private(set) var fatalLine: String?
    /// Advice for the most specific failure recognised so far.
    public private(set) var hint: String?

    public init() {}

    /// Updates state from one output line and says how the line should be presented.
    @discardableResult
    public mutating func consume(_ line: String) -> LineSeverity {
        let text = line.lowercased()
        let fatalMarkers = ["failed", "invalid device id", "does not match expected", "target device was not found",
                            "unable to locate", "no tool", "aborted"]
        let isFatal = fatalMarkers.contains(where: text.contains)

        // A failure line such as "Programming Target Failed." must not mark earlier steps as done.
        if isFatal {
            // no stage change
        } else if text.contains("connecting to") || text.contains("currently loaded firmware") {
            advance(to: .connecting)
        } else if text.hasPrefix("erasing") || text.contains("device erased") {
            advance(to: .erasing)
        } else if text.hasPrefix("programming") && !text.contains("download") {
            // "Programming download..." is MPLAB writing firmware into the programmer, not the chip.
            advance(to: .programming)
        } else if text.contains("verify report") || text.hasPrefix("verif") {
            advance(to: .verifying)
        } else if text.hasPrefix("reading") {
            advance(to: .reading)
        }

        if text.contains("downloading") && (text.contains("firmware") || text.contains("rs") || text.contains("ap") || text.contains("bootloader")) {
            loadingToolFirmware = true
        }
        if let match = line.firstMatch(of: /(?i)firmware suite version\.*\s*(\d+\.\d+\.\d+)/) {
            toolFirmwareVersion = String(match.1)
        }
        if let match = line.firstMatch(of: /(?i)target device\s+(\S+)\s+found/) {
            detectedTargetDevice = String(match.1)
        }
        if let match = line.firstMatch(of: /(?i)target device id\s*\(0x([0-9a-f]+)\)/) {
            reportedDeviceID = UInt16(match.1, radix: 16)
        }
        if let match = line.firstMatch(of: /(?i)device revision id\s*[=:]\s*(\S+)/) {
            deviceRevision = String(match.1)
        } else if let match = line.firstMatch(of: /(?i)device id\s*[=:]\s*(\S+)/) {
            deviceID = String(match.1)
        }

        if text.contains("program succeeded") { programSucceeded = true }
        if text.contains("verify succeeded") { verifySucceeded = true }
        if text.contains("operation succeeded") { operationSucceeded = true }

        if let advice = Self.hint(for: text) { hint = advice }
        // A readable but unexpected DEVID means a different chip is fitted, not a wiring fault.
        if let id = reportedDeviceID, text.contains("target device id"), let part = PICDevice.identify(deviceID: id) {
            hint = String(format: "The chip reports device ID 0x%04X, which is a %@. Select %@ under Device and try again.", id, part.name, part.name)
        }

        if isFatal {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            errorLines.append(trimmed)
            if fatalLine == nil { fatalLine = trimmed }
            return .error
        }
        if text.contains("error") || text.contains("invalid") || text.contains("could not") || text.contains("exception") {
            errorLines.append(line.trimmingCharacters(in: .whitespaces))
            return .error
        }
        if text.contains("succeeded") || text.contains("successful") || text.contains("complete")
            || text.hasSuffix(" found.") || text.contains("target voltage detected") {
            return .success
        }
        if text.contains("warning") || text.contains("caution") || text.contains("power is enabled") {
            return .warning
        }
        return .info
    }

    /// Whether the run did what was asked: exit code 0, no failure lines, and the success
    /// messages for each requested step.
    public func succeeded(exitCode: Int32, operation: IPEInvocation.Operation) -> Bool {
        guard exitCode == 0, fatalLine == nil else { return false }
        switch operation {
        case let .program(verify):
            return programSucceeded && (!verify || verifySucceeded)
        case .verify:
            return verifySucceeded
        case .readDeviceID, .readToHexFile, .erase, .blankCheck:
            return true
        }
    }

    /// The best one-line explanation of a failed run.
    public func failureSummary(exitCode: Int32, operation: IPEInvocation.Operation) -> String {
        if let fatalLine { return fatalLine }
        if let last = errorLines.last { return last }
        if exitCode != 0 { return "ipecmd stopped with exit code \(exitCode)." }
        switch operation {
        case .program: return "ipecmd finished without reporting \"Program Succeeded\"."
        case .verify: return "ipecmd finished without reporting \"Verify Succeeded\"."
        default: return "ipecmd did not report success."
        }
    }

    private static func hint(for text: String) -> String? {
        if text.contains("could not detect target voltage") || text.contains("no voltage has been detected") || text.contains("target device was not found") {
            return "The programmer cannot see power on the target. Power the RFGEN44, or turn on \"Power the target from the programmer\", and check the ICSP cable is plugged in with pin 1 (▶) on MCLR."
        }
        if text.contains("more power than the debug tool can provide") {
            return "The board draws more current than the PICkit 3 can supply. Power the RFGEN44 from its own supply and turn off \"Power the target from the programmer\"."
        }
        if text.contains("invalid device id") || text.contains("device id (0x0)") {
            return "The chip did not answer. Check the ICSP wiring (MCLR, PGD, PGC, GND), the cable orientation, and that the board is powered."
        }
        if text.contains("does not match expected device id") {
            return "The chip on the board is not the selected device. Check the Device setting."
        }
        if text.contains("connection failed") || text.contains("failed to connect") {
            return "MPLAB could not talk to the programmer. If it is a PICkit 3 that was used with the standalone PICkit 3 Programmer App, put it back in MPLAB mode: unplug it, hold its push-button, plug it in while still holding it, release after 2–3 seconds, and try again. Otherwise plug it straight into the Mac, not through a hub or dock."
        }
        if text.contains("unable to locate dfp") || text.contains("could not find device") || text.contains("required pack") {
            return "This MPLAB installation has no support pack for the selected chip. Open MPLAB X IPE, choose Tools ▸ Packs, and install PIC16F1xxxx_DFP."
        }
        if text.contains("verify failed") || text.contains("verification failed") {
            return "What is on the chip does not match the file. Run Program & Verify again. If it keeps failing, check the wiring and power, and shorten the ICSP cable."
        }
        return nil
    }

    private mutating func advance(to newStage: IPEStage) {
        if stage.map({ newStage > $0 }) ?? true { stage = newStage }
    }
}
