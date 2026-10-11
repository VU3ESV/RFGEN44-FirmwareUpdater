import AppKit
import CryptoKit
import FirmwareCore
import Foundation

struct LogLine: Identifiable, Sendable {
    enum Kind: Sendable { case command, output, app }

    let id: Int
    let date: Date
    let text: String
    let kind: Kind
    let severity: LineSeverity
}

struct Outcome: Equatable {
    let success: Bool
    let title: String
    let detail: String?
    var action: OutcomeAction? = nil
}

/// A one-click fix offered with a failure.
enum OutcomeAction: Equatable {
    case useDevice(PICDevice)
    case switchPICkitToMPLABMode
}

enum Activity: Equatable {
    case programAndVerify, verify, testConnection, readToFile, switchingPICkit

    var title: String {
        switch self {
        case .programAndVerify: "Programming"
        case .verify: "Verifying"
        case .testConnection: "Testing connection"
        case .readToFile: "Reading device"
        case .switchingPICkit: "Switching PICkit 3 to MPLAB mode"
        }
    }
}

/// What the app knows about an attached PICkit 3's own firmware.
enum PICkitState: Equatable {
    case checking
    case mplab(suite: String?)
    case bootloader
    case scripting(version: String)
    case switching
    case unresponsive
    case switchFailed(String)
}

enum StageState: Equatable {
    case pending, active, done, failed
}

struct LoadedFirmware {
    let url: URL
    /// The exact bytes that were parsed and hashed; these, not the file on disk, are what gets programmed.
    let data: Data
    let hex: IntelHex
    let sha256: String

    var fileSize: Int { data.count }
}

@MainActor
@Observable
final class UpdaterModel {
    // MARK: Firmware

    private(set) var firmware: LoadedFirmware?
    private(set) var firmwareError: String?
    var device: PICDevice = .pic16f1459 {
        didSet {
            defaults.set(device.name, forKey: Keys.device)
            if !device.supports(voltage: powerVoltage) { powerVoltage = 3.3 }
        }
    }

    var summary: FirmwareSummary? { firmware.map { FirmwareSummary(hex: $0.hex, device: device) } }

    // MARK: Programmer

    let usb = USBToolMonitor()
    var selectedProgrammerID: UInt64?

    var selectedProgrammer: USBDevice? {
        let programmers = usb.programmers
        return programmers.first { $0.id == selectedProgrammerID } ?? (programmers.count == 1 ? programmers.first : nil)
    }

    /// Firmware state per attached PICkit 3, keyed by USB registry ID.
    private(set) var pickitStates: [UInt64: PICkitState] = [:]
    /// A PICkit 3 firmware check or mode switch is running; ipecmd must wait for it.
    private(set) var isCheckingProgrammer = false
    /// Fix programmer problems without asking: switch a PICkit 3 out of scripting firmware, and
    /// follow the chip when it reports the F/LF version of the selected part.
    var autoFix = true { didSet { defaults.set(autoFix, forKey: Keys.autoFix) } }

    private(set) var installations: [IPECmdInstallation] = []
    private(set) var customInstallation: IPECmdInstallation?
    private(set) var isLocatingIPE = false
    /// The custom choice if any, otherwise the newest installation that still supports the selected
    /// programmer. With nothing plugged in it plans for a PICkit 3, the programmer this app is for.
    var ipecmd: IPECmdInstallation? {
        if let customInstallation { return customInstallation }
        let kind = selectedProgrammer?.programmer ?? usb.programmers.first?.programmer ?? .pickit3
        return installations.first { $0.supports(kind) } ?? installations.first
    }

    // MARK: Options

    var powerTarget = false { didSet { defaults.set(powerTarget, forKey: Keys.powerTarget) } }
    var powerVoltage = 5.0 { didSet { defaults.set(powerVoltage, forKey: Keys.powerVoltage) } }
    var readbackAfterProgramming = true { didSet { defaults.set(readbackAfterProgramming, forKey: Keys.readback) } }

    // MARK: Run state

    private(set) var activity: Activity?
    private(set) var stages: [IPEStage] = []
    private(set) var stageStates: [IPEStage: StageState] = [:]
    private(set) var outcome: Outcome?
    private(set) var verification: VerificationReport?
    private(set) var log: [LogLine] = []
    private(set) var targetDescription: String?
    /// Extra progress note under the stage track, e.g. while MPLAB loads firmware into the PICkit.
    private(set) var statusDetail: String?

    var isBusy: Bool { activity != nil }

    @ObservationIgnored private var runTask: Task<Void, Never>?
    /// Automatic fixes made during the current activity, reported with its outcome.
    @ObservationIgnored private var fixesThisRun: [String] = []
    @ObservationIgnored private var nextLogID = 0
    @ObservationIgnored private let defaults = UserDefaults.standard

    private enum Keys {
        static let firmwarePath = "lastFirmwarePath"
        static let device = "device"
        static let powerTarget = "powerTarget"
        static let powerVoltage = "powerVoltage"
        static let readback = "readbackAfterProgramming"
        static let customIPECmd = "customIPECmdPath"
        static let autoFix = "autoFixProgrammer"
    }

    init() {
        Self.migrateLegacyDefaults()
        if let name = defaults.string(forKey: Keys.device), let saved = PICDevice.supported.first(where: { $0.name == name }) {
            device = saved
        }
        powerTarget = defaults.bool(forKey: Keys.powerTarget)
        if defaults.object(forKey: Keys.powerVoltage) != nil { powerVoltage = defaults.double(forKey: Keys.powerVoltage) }
        if defaults.object(forKey: Keys.readback) != nil { readbackAfterProgramming = defaults.bool(forKey: Keys.readback) }
        if defaults.object(forKey: Keys.autoFix) != nil { autoFix = defaults.bool(forKey: Keys.autoFix) }
        if let path = defaults.string(forKey: Keys.customIPECmd) {
            customInstallation = IPECmdLocator.installation(forUserSelection: URL(fileURLWithPath: path))
        }
        if !device.supports(voltage: powerVoltage) { powerVoltage = 3.3 }
    }

    /// Settings from builds before 1.0.0, whose bundle identifier was com.rfgen44.firmwareupdater.
    private static func migrateLegacyDefaults() {
        let legacyDomain = "com.rfgen44.firmwareupdater"
        let defaults = UserDefaults.standard
        guard Bundle.main.bundleIdentifier != legacyDomain,
              !defaults.bool(forKey: "migratedLegacyDefaults"),
              let legacy = defaults.persistentDomain(forName: legacyDomain)
        else { return }
        for (key, value) in legacy where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: "migratedLegacyDefaults")
    }

    func start() {
        usb.onChange = { [weak self] in self?.programmersChanged() }
        usb.start()
        locateIPE()
        if firmware == nil, let path = defaults.string(forKey: Keys.firmwarePath), FileManager.default.fileExists(atPath: path) {
            openFirmware(URL(fileURLWithPath: path), adoptDeviceFromName: false)
        }
        #if DEBUG
        // UI testing without clicking: RFGEN44_AUTORUN=program|verify|test|wiring runs one action at launch.
        if let action = ProcessInfo.processInfo.environment["RFGEN44_AUTORUN"] {
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                switch action {
                case "program": programAndVerify()
                case "verify": verify()
                case "test": testConnection()
                case "wiring": NotificationCenter.default.post(name: .showWiring, object: nil)
                default: break
                }
            }
        }
        #endif
    }

    // MARK: Firmware loading

    func openFirmware(_ url: URL, adoptDeviceFromName: Bool = true) {
        do {
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .ascii) ?? String(data: data, encoding: .utf8) else {
                throw IntelHex.ParseError(line: 0, reason: "File is not a text file")
            }
            let hex = try IntelHex(text: text)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            firmware = LoadedFirmware(url: url, data: data, hex: hex, sha256: digest)
            firmwareError = nil
            defaults.set(url.path, forKey: Keys.firmwarePath)
            // A file named for PIC16F1459 also suits a PIC16LF1459, so keep an F/LF choice already made.
            if adoptDeviceFromName, let guessed = PICDevice.guess(fromFileName: url.lastPathComponent), !guessed.isVariant(of: device) {
                device = guessed
            }
            outcome = nil
            verification = nil
            appendLog("Loaded \(url.lastPathComponent) (\(hex.dataRecordCount) data records)", kind: .app)
        } catch {
            firmware = nil
            firmwareError = "\(url.lastPathComponent) is not a valid Intel HEX file. \(error.localizedDescription)"
            appendLog(firmwareError!, kind: .app, severity: .error)
        }
    }

    func reloadFirmware() {
        if let url = firmware?.url { openFirmware(url, adoptDeviceFromName: false) }
    }

    // MARK: ipecmd discovery

    func locateIPE() {
        isLocatingIPE = true
        Task {
            let found = await Task.detached(priority: .userInitiated) { IPECmdLocator.locateAll() }.value
            installations = found
            isLocatingIPE = false
            if let ipecmd {
                appendLog("Using MPLAB IPE \(ipecmd.version.map { "\($0) " } ?? "")at \(ipecmd.displayPath)", kind: .app)
            } else {
                appendLog("MPLAB IPE (ipecmd) not found. Install MPLAB X IDE or choose ipecmd in Settings.", kind: .app, severity: .warning)
            }
        }
    }

    @discardableResult
    func useCustomIPECmd(_ url: URL) -> Bool {
        guard let installation = IPECmdLocator.installation(forUserSelection: url) else { return false }
        customInstallation = installation
        defaults.set(url.path, forKey: Keys.customIPECmd)
        appendLog("Using ipecmd at \(installation.displayPath)", kind: .app)
        return true
    }

    func clearCustomIPECmd() {
        customInstallation = nil
        defaults.removeObject(forKey: Keys.customIPECmd)
    }

    // MARK: Preflight

    /// Why the selected action cannot run yet, or nil when everything is ready.
    func blockingReason(needsFirmware: Bool) -> String? {
        guard let ipecmd else { return "MPLAB IPE was not found. Install MPLAB X IDE v6.20 (it includes IPE) or locate ipecmd in Settings." }
        if usb.programmers.isEmpty { return "Connect the PICkit 3 to a USB port." }
        guard let selected = selectedProgrammer, let kind = selected.programmer else { return "Select which programmer to use." }
        if isCheckingProgrammer { return "Checking the PICkit 3's firmware…" }
        switch pickitStates[selected.id] {
        case let .scripting(version)?:
            return "The PICkit 3 is running the Programmer App's scripting firmware (v\(version)), which MPLAB can't use. Switch it to MPLAB mode from the More menu."
        case let .switchFailed(reason)?:
            return "The PICkit 3 couldn't be switched to MPLAB mode: \(reason)"
        default:
            break
        }
        if !ipecmd.supports(kind) {
            return "MPLAB IPE \(ipecmd.version ?? "") no longer supports the \(kind.displayName). Install MPLAB X v6.20, the last version that does (it can sit alongside newer versions)."
        }
        if needsFirmware {
            guard let summary else { return "Choose a firmware .hex file." }
            if !summary.fitsDevice {
                return "The firmware has data outside \(device.name) memory. Check the device selection."
            }
        }
        return nil
    }

    /// Verifying against a code-protected image is impossible: the device reads back zeros.
    var canVerifySeparately: Bool { summary?.codeProtectionEnabled != true }

    var verifyBlockingReason: String? {
        blockingReason(needsFirmware: true) ?? (canVerifySeparately ? nil : "This firmware turns on code protection, so the device cannot be read back to verify it.")
    }

    // MARK: Actions

    func programAndVerify() {
        guard let firmware else { return }
        let separateVerify = canVerifySeparately
        let readback = readbackAfterProgramming && separateVerify
        var plan: [IPEStage] = [.connecting, .erasing, .programming, .verifying]
        if readback { plan.append(.reading) }
        begin(.programAndVerify, stages: plan) { model, workDir in
            let hexPath = try model.stageFirmware(firmware, in: workDir)
            try await model.runIPE(.program(verify: separateVerify), hexPath: hexPath, workDir: workDir)
            var detail = separateVerify
                ? "ipecmd programmed \(model.device.name) and verified it."
                : "ipecmd programmed \(model.device.name) and checked each word as it wrote it. The firmware is code-protected, so the device can't be read back for a full verify."
            if readback {
                let report = try await model.readBackAndCompare(firmware, workDir: workDir)
                detail += " Read-back compare matched \(report.wordsCompared.formatted()) words."
            }
            return Outcome(success: true, title: "Firmware uploaded and verified", detail: detail)
        }
    }

    func verify() {
        guard let firmware else { return }
        var plan: [IPEStage] = [.connecting, .verifying]
        if readbackAfterProgramming { plan.append(.reading) }
        begin(.verify, stages: plan) { model, workDir in
            let hexPath = try model.stageFirmware(firmware, in: workDir)
            try await model.runIPE(.verify, hexPath: hexPath, workDir: workDir)
            var detail = "\(model.device.name) contents match \(firmware.url.lastPathComponent)."
            if model.readbackAfterProgramming {
                let report = try await model.readBackAndCompare(firmware, workDir: workDir)
                detail += " Read-back compare matched \(report.wordsCompared.formatted()) words."
            }
            return Outcome(success: true, title: "Device matches the firmware", detail: detail)
        }
    }

    func testConnection() {
        begin(.testConnection, stages: [.connecting]) { model, workDir in
            let parser = try await model.runIPE(.readDeviceID, hexPath: nil, workDir: workDir)
            let found = parser.detectedTargetDevice ?? model.device.name
            let id = [parser.deviceID.map { "Device ID \($0)" }, parser.deviceRevision.map { "revision \($0)" }]
                .compactMap { $0 }.joined(separator: ", ")
                .nonEmpty.map { " · \($0)" } ?? ""
            model.targetDescription = "\(found)\(id)"
            return Outcome(success: true, title: "Programmer and target are connected", detail: "Found \(found)\(id).")
        }
    }

    func readDevice(to destination: URL) {
        begin(.readToFile, stages: [.connecting, .reading]) { model, workDir in
            let readback = workDir.appendingPathComponent("readback.hex")
            try await model.runIPE(.readToHexFile(readback.path), hexPath: nil, workDir: workDir)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: readback, to: destination)
            return Outcome(success: true, title: "Device memory saved", detail: destination.path)
        }
    }

    func cancel() {
        runTask?.cancel()
    }

    func perform(_ action: OutcomeAction) {
        switch action {
        case let .useDevice(part):
            device = part
            outcome = nil
            stages = []
            appendLog("Device set to \(part.name)", kind: .app)
        case .switchPICkitToMPLABMode:
            switchPICkitToMPLABMode()
        }
    }

    /// Manual version of the automatic fix: does what "Revert to MPLAB mode" in Microchip's
    /// PICkit 3 Programmer App does, so MPLAB can use the PICkit again.
    func switchPICkitToMPLABMode() {
        guard let pickit = singlePICkit3 else { return }
        begin(.switchingPICkit, stages: []) { model, _ in
            guard await model.inspectPICkit(pickit.id, switchIfNeeded: true) else {
                if case let .switchFailed(reason)? = model.pickitStates[pickit.id] { throw RunFailure(message: reason) }
                return Outcome(success: true, title: "PICkit 3 is already in MPLAB mode", detail: nil)
            }
            return Outcome(
                success: true,
                title: "PICkit 3 is in MPLAB mode",
                detail: "MPLAB loads its own firmware onto the PICkit the next time it connects, which takes about a minute."
            )
        }
    }

    // MARK: Programmer health

    /// The one attached, real PICkit 3. The firmware probe talks to the first PICkit 3 it finds,
    /// so it only runs when there is exactly one.
    private var singlePICkit3: USBDevice? {
        let pickits = usb.programmers.filter { $0.programmer == .pickit3 && !$0.isSimulated }
        return pickits.count == 1 ? pickits[0] : nil
    }

    private func programmersChanged() {
        let attached = Set(usb.devices.map(\.id))
        pickitStates = pickitStates.filter { attached.contains($0.key) }
        checkPICkitIfIdle()
    }

    /// Checks a newly attached PICkit 3's firmware when nothing else is using it, and with
    /// auto-fix on, switches it out of scripting firmware straight away.
    private func checkPICkitIfIdle() {
        guard activity == nil, !isCheckingProgrammer, let pickit = singlePICkit3, pickitStates[pickit.id] == nil else { return }
        isCheckingProgrammer = true
        Task {
            await inspectPICkit(pickit.id, switchIfNeeded: autoFix)
            isCheckingProgrammer = false
            // A switched PICkit comes back under a new USB ID; check that one too.
            checkPICkitIfIdle()
        }
    }

    /// Reads the PICkit 3's firmware state and, if asked, switches scripting firmware to MPLAB mode.
    /// Returns true when it switched.
    @discardableResult
    private func inspectPICkit(_ id: UInt64, switchIfNeeded: Bool) async -> Bool {
        pickitStates[id] = .checking
        switch await runBlocking({ PICkit3Probe.identify() }) {
        case let .mplab(suite):
            pickitStates[id] = .mplab(suite: suite)
            appendLog("PICkit 3 runs MPLAB firmware\(suite.map { " \($0)" } ?? "").", kind: .app)
            return false
        case .mplabBootloader:
            pickitStates[id] = .bootloader
            appendLog("PICkit 3 is in its MPLAB bootloader; MPLAB loads its firmware on the next connect.", kind: .app)
            return false
        case .noReply, .unrecognised:
            pickitStates[id] = .unresponsive
            appendLog("PICkit 3 did not answer a firmware query.", kind: .app, severity: .warning)
            return false
        case let .scripting(version):
            pickitStates[id] = .scripting(version: version)
            appendLog("PICkit 3 is running the PICkit 3 Programmer App's scripting firmware (v\(version)), which MPLAB can't use.", kind: .app, severity: .warning)
            guard switchIfNeeded else { return false }
        }

        pickitStates[id] = .switching
        appendLog("Switching the PICkit 3 to MPLAB mode…", kind: .app)
        switch await runBlocking({ PICkit3Probe.switchToMPLABMode() }) {
        case .switched:
            pickitStates[id] = nil // it re-enumerates under a new USB ID
            appendLog("PICkit 3 restarted in MPLAB mode.", kind: .app, severity: .success)
            await waitForPICkit3()
            return true
        case .notNeeded:
            pickitStates[id] = nil
            return false
        case .bootloaderMissing:
            let reason = "it has no MPLAB bootloader. Reinstall it with Microchip's PICkit 3 Programmer App on Windows, using Tools ▸ Download PICkit Operating System."
            pickitStates[id] = .switchFailed(reason)
            appendLog("Can't switch the PICkit 3: \(reason)", kind: .app, severity: .error)
            return false
        case let .failed(reason):
            pickitStates[id] = .switchFailed(reason)
            appendLog("Switching the PICkit 3 failed: \(reason)", kind: .app, severity: .error)
            return false
        }
    }

    /// After a mode switch, give the USB monitor a moment to see the PICkit 3 again.
    private func waitForPICkit3() async {
        for _ in 0..<20 where singlePICkit3 == nil {
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    /// Fixes the cause of a failed ipecmd run when it is safe to do without asking.
    /// Returns a description of the fix, or nil when there is nothing to fix automatically.
    private func autoFix(after parser: IPEOutputParser, summary: String, tool: ProgrammerKind) async -> String? {
        // The chip is the F/LF twin of the selected part: same firmware, so follow the chip.
        if let id = parser.reportedDeviceID, let fitted = PICDevice.identify(deviceID: id), fitted != device, fitted.isVariant(of: device) {
            let selected = device.name
            device = fitted
            return "The chip is a \(fitted.name), not a \(selected). Switched the device setting."
        }
        // A PICkit 3 left in the Programmer App's scripting firmware: switch it to MPLAB mode.
        if tool == .pickit3, summary.lowercased().contains("connection failed"), let pickit = singlePICkit3 {
            isCheckingProgrammer = true
            defer { isCheckingProgrammer = false }
            if await inspectPICkit(pickit.id, switchIfNeeded: true) {
                return "The PICkit 3 was running the Programmer App's scripting firmware. Switched it to MPLAB mode."
            }
        }
        return nil
    }

    // MARK: Run machinery

    private struct RunFailure: LocalizedError {
        let message: String
        var action: OutcomeAction? = nil
        var errorDescription: String? { message }
    }

    private func begin(
        _ newActivity: Activity,
        stages plan: [IPEStage],
        operation: @escaping @MainActor (UpdaterModel, URL) async throws -> Outcome
    ) {
        guard activity == nil else { return }
        activity = newActivity
        stages = plan
        stageStates = Dictionary(uniqueKeysWithValues: plan.map { ($0, .pending) })
        outcome = nil
        verification = nil
        statusDetail = nil
        fixesThisRun = []
        appendLog(newActivity == .switchingPICkit
            ? "— \(newActivity.title) —"
            : "— \(newActivity.title) \(device.name) with \(selectedProgrammer?.displayName ?? "programmer") —", kind: .app)

        runTask = Task {
            let clock = ContinuousClock()
            let started = clock.now
            let workDir = Self.workRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: workDir) }

            do {
                // Never talk to the PICkit 3 from two places at once.
                while isCheckingProgrammer { try await Task.sleep(for: .milliseconds(100)) }
                try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
                var result = try await operation(self, workDir)
                for stage in plan { stageStates[stage] = .done }
                let seconds = (clock.now - started).formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1)))
                let fixed = fixesThisRun.isEmpty ? nil : "Fixed automatically: " + fixesThisRun.joined(separator: " ")
                result = Outcome(success: true, title: result.title, detail: [result.detail, fixed, "Took \(seconds)."].compactMap { $0 }.joined(separator: " "))
                outcome = result
                appendLog("✓ \(result.title)", kind: .app, severity: .success)
                NSSound(named: "Glass")?.play()
            } catch is CancellationError {
                markActiveStageFailed()
                outcome = Outcome(success: false, title: "Cancelled", detail: newActivity == .programAndVerify
                    ? "Programming was interrupted. The device may hold incomplete firmware — run Program & Verify again."
                    : nil)
                appendLog("Cancelled by user", kind: .app, severity: .warning)
            } catch {
                markActiveStageFailed()
                outcome = Outcome(
                    success: false,
                    title: "\(newActivity.title) failed",
                    detail: error.localizedDescription,
                    action: (error as? RunFailure)?.action
                )
                appendLog("✗ \(error.localizedDescription)", kind: .app, severity: .error)
                NSSound(named: "Basso")?.play()
            }
            activity = nil
            runTask = nil
            statusDetail = nil
            checkPICkitIfIdle()
        }
    }

    private func markActiveStageFailed() {
        if let active = stages.first(where: { stageStates[$0] == .active }) ?? stages.first(where: { stageStates[$0] == .pending }) {
            stageStates[active] = .failed
        }
    }

    private func setStage(_ stage: IPEStage) {
        guard stages.contains(stage) else { return }
        for earlier in stages where earlier < stage && stageStates[earlier] != .done {
            stageStates[earlier] = .done
        }
        if stageStates[stage] != .done { stageStates[stage] = .active }
    }

    /// ipecmd's shell wrapper splits arguments on spaces, so every path it sees lives under a space-free folder.
    private static var workRoot: URL {
        let temp = FileManager.default.temporaryDirectory
        let base = temp.path.contains(" ") ? URL(fileURLWithPath: "/private/tmp") : temp
        return base.appendingPathComponent("RFGEN44Updater", isDirectory: true)
    }

    /// Writes the loaded firmware into the work folder, so ipecmd programs exactly what was shown
    /// and what the read-back compare checks against, even if the file has changed on disk since.
    private func stageFirmware(_ firmware: LoadedFirmware, in workDir: URL) throws -> String {
        let copy = workDir.appendingPathComponent("firmware.hex")
        try firmware.data.write(to: copy)
        return copy.path
    }

    /// Runs ipecmd once. If it fails for a reason the app can fix itself (see `autoFix`), it fixes
    /// it and runs the same operation again; otherwise it explains the failure.
    @discardableResult
    private func runIPE(_ operation: IPEInvocation.Operation, hexPath: String?, workDir: URL) async throws -> IPEOutputParser {
        var fixesApplied: Set<String> = []
        while true {
            let (parser, exitCode, tool) = try await runIPEOnce(operation, hexPath: hexPath, workDir: workDir)
            if parser.succeeded(exitCode: exitCode, operation: operation) { return parser }

            let summary = parser.failureSummary(exitCode: exitCode, operation: operation)
            if autoFix, let fix = await autoFix(after: parser, summary: summary, tool: tool), fixesApplied.insert(fix).inserted {
                fixesThisRun.append(fix)
                appendLog("↻ \(fix) Trying again…", kind: .app, severity: .warning)
                continue
            }

            var hint = parser.hint
            var action: OutcomeAction?
            if let id = parser.reportedDeviceID, let fitted = PICDevice.identify(deviceID: id), fitted != device {
                action = .useDevice(fitted)
            }
            if tool == .pickit3, let pickit = singlePICkit3 {
                switch pickitStates[pickit.id] {
                case .scripting?:
                    hint = "This PICkit 3 is running the standalone PICkit 3 Programmer App's scripting firmware, which MPLAB can't use."
                    action = .switchPICkitToMPLABMode
                case let .switchFailed(reason)?:
                    hint = "The PICkit 3 couldn't be switched to MPLAB mode: \(reason)"
                default:
                    break
                }
            }
            throw RunFailure(message: [summary, hint].compactMap { $0 }.joined(separator: "\n\n"), action: action)
        }
    }

    private func runIPEOnce(
        _ operation: IPEInvocation.Operation,
        hexPath: String?,
        workDir: URL
    ) async throws -> (IPEOutputParser, Int32, ProgrammerKind) {
        guard let ipecmd else { throw RunFailure(message: "MPLAB IPE (ipecmd) is not available.") }
        guard let programmer = selectedProgrammer, let kind = programmer.programmer else {
            throw RunFailure(message: "The programmer was disconnected.")
        }
        let sameKind = usb.programmers.filter { $0.programmer == kind }
        let invocation = IPEInvocation(
            tool: kind,
            toolSerialNumber: sameKind.count > 1 ? programmer.serialNumber : nil,
            part: device.ipecmdPartName,
            hexFilePath: hexPath,
            powerTargetVoltage: powerTarget ? powerVoltage : nil
        )
        let arguments = invocation.arguments(for: operation)
        appendLog("$ ipecmd " + arguments.joined(separator: " "), kind: .command)

        var parser = IPEOutputParser()
        var exitCode: Int32 = -1
        let events = ProcessRunner.run(
            executable: ipecmd.executableURL,
            arguments: ipecmd.processArguments(arguments),
            workingDirectory: workDir
        )
        for try await event in events {
            switch event {
            case let .output(line):
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.allSatisfy({ $0 == "*" }) else { continue }
                let wasLoadingFirmware = parser.loadingToolFirmware
                let severity = parser.consume(trimmed)
                appendLog(trimmed, kind: .output, severity: severity)
                if let stage = parser.stage { setStage(stage) }
                if parser.loadingToolFirmware && !wasLoadingFirmware {
                    statusDetail = "MPLAB is loading its firmware onto the \(kind.displayName). This happens once and takes about a minute."
                } else if parser.loadingToolFirmware, parser.detectedTargetDevice != nil || trimmed.lowercased().contains("target voltage") {
                    statusDetail = nil
                }
            case let .exited(code):
                exitCode = code
            }
        }
        try Task.checkCancellation()
        statusDetail = nil
        // Once MPLAB has reached the chip, the firmware it reported last is what the PICkit now runs.
        if kind == .pickit3, parser.detectedTargetDevice != nil, let version = parser.toolFirmwareVersion, let pickit = singlePICkit3 {
            pickitStates[pickit.id] = .mplab(suite: version)
        }
        return (parser, exitCode, kind)
    }

    private func readBackAndCompare(_ firmware: LoadedFirmware, workDir: URL) async throws -> VerificationReport {
        setStage(.reading)
        let readbackURL = workDir.appendingPathComponent("readback.hex")
        try await runIPE(.readToHexFile(readbackURL.path), hexPath: nil, workDir: workDir)

        let readback: IntelHex
        do {
            readback = try IntelHex(contentsOf: readbackURL)
        } catch {
            throw RunFailure(message: "Could not read the device memory file ipecmd produced: \(error.localizedDescription)")
        }
        let report = ReadbackVerifier.compare(expected: firmware.hex, readback: readback, device: device)
        verification = report
        appendLog(
            "Read-back compare: \(report.programWordsCompared) program, \(report.userIDWordsCompared) user ID and \(report.configWordsCompared) config words; \(report.mismatches.count) mismatches",
            kind: .app,
            severity: report.passed ? .success : .error
        )
        guard report.passed else {
            if !report.readbackContainsProgramMemory {
                throw RunFailure(message: "The read-back file contained no program memory.")
            }
            if report.looksCodeProtected {
                throw RunFailure(message: "Program memory reads back as zeros. The device is code-protected, so it cannot be compared.")
            }
            let first = report.mismatches[0]
            throw RunFailure(message: String(
                format: "Read-back compare found %d mismatched words (first at 0x%04X: expected 0x%04X, read 0x%04X).",
                report.mismatches.count, first.wordAddress, first.expected, first.actual
            ))
        }
        return report
    }

    // MARK: Log

    func appendLog(_ text: String, kind: LogLine.Kind, severity: LineSeverity = .info) {
        log.append(LogLine(id: nextLogID, date: Date(), text: text, kind: kind, severity: severity))
        nextLogID += 1
        if log.count > 5000 { log.removeFirst(log.count - 5000) }
    }

    func clearLog() {
        log.removeAll()
    }

    var logText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return log.map { "\(formatter.string(from: $0.date))  \($0.text)" }.joined(separator: "\n")
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// Runs blocking work (direct USB I/O with its own run loop) on a GCD thread rather than the Swift concurrency pool.
func runBlocking<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
    }
}

extension PICDevice {
    /// LF parts are limited to 3.6 V; F parts run from 5 V.
    var isLowVoltagePart: Bool { name.uppercased().contains("LF") }

    func supports(voltage: Double) -> Bool { !isLowVoltagePart || voltage <= 3.6 }
}
