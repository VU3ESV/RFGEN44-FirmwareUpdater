import Foundation
import Testing
@testable import FirmwareCore

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
private let fakeIPECmd = fixtures.appendingPathComponent("fake-ipecmd.sh")
private let firmwarePath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Tests/FirmwareCoreTests/Fixtures/sample-pic16f1459.hex").path

@Suite struct IPEInvocationTests {
    @Test func programAndVerifyArguments() {
        let invocation = IPEInvocation(tool: .pickit3, part: "16F1459", hexFilePath: "/tmp/fw.hex")
        #expect(invocation.arguments(for: .program(verify: true)) == ["-TPPK3", "-P16F1459", "-F/tmp/fw.hex", "-M", "-Y", "-OL"])
        #expect(invocation.arguments(for: .program(verify: false)) == ["-TPPK3", "-P16F1459", "-F/tmp/fw.hex", "-M", "-OL"])
    }

    @Test func serialPowerAndReadArguments() {
        let invocation = IPEInvocation(tool: .pickit3, toolSerialNumber: "BUR123456789", part: "16F1459", powerTargetVoltage: 5)
        #expect(invocation.arguments(for: .readToHexFile("/tmp/out.hex")) == ["-TPPK3", "-TSBUR123456789", "-P16F1459", "-W5.0", "-GF/tmp/out.hex", "-OL"])
        #expect(invocation.arguments(for: .readDeviceID).contains("-I"))
    }

    @Test func pickit3NeedsMPLAB620OrOlder() {
        func install(_ version: String) -> IPECmdInstallation {
            IPECmdInstallation(script: URL(fileURLWithPath: "/x/ipecmd.sh"), version: version)
        }
        #expect(install("v6.20").supports(.pickit3))
        #expect(install("v6.05").supports(.pickit3))
        #expect(install("v5.50").supports(.pickit3))
        #expect(!install("v6.25").supports(.pickit3))
        #expect(!install("v6.35").supports(.pickit3))
        #expect(install("v6.35").supports(.pickit4))
    }

    @Test func recognisesProgrammersByUSBID() {
        #expect(ProgrammerKind(vendorID: 0x04D8, productID: 0x900A) == .pickit3)
        #expect(ProgrammerKind(vendorID: 0x04D8, productID: 0x9036) == .pickit5)
        #expect(ProgrammerKind(vendorID: 0x04D8, productID: 0x9017) == nil) // PICkit 4 bootloader
        #expect(ProgrammerKind(vendorID: 0x05AC, productID: 0x900A) == nil)
    }
}

@Suite struct IPECmdLocatorTests {
    @Test func findsMacInstallsAndOrdersNewestFirst() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("locator-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for version in ["v6.20", "v6.35"] {
            let bin = root.appendingPathComponent("\(version)/mplab_platform/mplab_ipe/bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try "#!/bin/bash\n".write(to: bin.appendingPathComponent("ipecmd.sh"), atomically: true, encoding: .utf8)
        }
        let found = IPECmdLocator.locateAll(roots: [root])
        #expect(found.map(\.version) == ["v6.35", "v6.20"])
        #expect(found.first { $0.supports(.pickit3) }?.version == "v6.20")
        #expect(found[0].executableURL.path == "/bin/bash")
        #expect(found[0].processArguments(["-TPPK3"]).last == "-TPPK3")

        let fromScript = IPECmdLocator.installation(
            forUserSelection: root.appendingPathComponent("v6.20/mplab_platform/mplab_ipe/bin/ipecmd.sh")
        )
        #expect(fromScript?.version == "v6.20")
        #expect(IPECmdLocator.installation(forUserSelection: root.appendingPathComponent("v6.20"))?.script.lastPathComponent == "ipecmd.sh")
    }
}

@Suite struct IPEOutputParserTests {
    /// PICkit 3 transcript from MPLAB X v6.20 (tardate/LittleArduinoProjects), adapted to the PIC16F1459.
    private let successfulRun = """
    DFP Version Used : PIC16F1xxxx_DFP,1.25.389,Microchip
    Connecting to MPLAB PICkit 3...
    Currently loaded firmware on PICkit 3
    Firmware Suite Version.....01.56.09
    Firmware type..............Enhanced Midrange
    Target device PIC16F1459 found.
    Device Revision ID = 1006
    Erasing...
    Erase successful
    Device Erased...
    Programming...
    The following memory area(s) will be programmed:
    program memory: start address = 0x0, end address = 0x1f7f
    configuration memory
    Programming/Verify complete
    PICKIT3 Program Report
    Device Type:PIC16F1459
    Program Succeeded.
    PK3 Verify Report
    Verification successful.
    Verify Succeeded.
    Operation Succeeded
    """

    @Test func followsASuccessfulProgramAndVerify() {
        var parser = IPEOutputParser()
        var stages: [IPEStage] = []
        for line in successfulRun.split(separator: "\n") {
            parser.consume(String(line))
            if let stage = parser.stage, stages.last != stage { stages.append(stage) }
        }
        #expect(stages == [.connecting, .erasing, .programming, .verifying])
        #expect(parser.detectedTargetDevice == "PIC16F1459")
        #expect(parser.deviceRevision == "1006")
        #expect(parser.succeeded(exitCode: 0, operation: .program(verify: true)))
        #expect(!parser.succeeded(exitCode: 1, operation: .program(verify: true)))
    }

    @Test func connectionFailedWithExitZeroIsAFailure() {
        var parser = IPEOutputParser()
        parser.consume("Connecting to MPLAB PICkit 3...")
        #expect(parser.consume("Connection Failed.") == .error)
        #expect(!parser.succeeded(exitCode: 0, operation: .readDeviceID))
        #expect(parser.failureSummary(exitCode: 0, operation: .readDeviceID) == "Connection Failed.")
        #expect(parser.hint?.contains("hold its push-button") == true)
    }

    /// Real MPLAB X v6.20 output with a PICkit 3 still running the Programmer App's scripting firmware.
    @Test func connectionFailureDoesNotAdvanceStages() {
        var parser = IPEOutputParser()
        for line in ["DFP Version Used : PIC12-16F1xxx_DFP,1.7.242,Microchip", "Connection Failed.",
                     "Connection Failed.", "Programming Target Failed.", "Operation Succeeded"] {
            parser.consume(line)
        }
        #expect(parser.stage == nil)
        #expect(!parser.succeeded(exitCode: 0, operation: .program(verify: true)))
        #expect(parser.failureSummary(exitCode: 0, operation: .program(verify: true)) == "Connection Failed.")
    }

    /// Real output: the RFGEN44 carries a PIC16LF1459 while PIC16F1459 was selected.
    @Test func namesThePartBehindAnUnexpectedDeviceID() {
        var parser = IPEOutputParser()
        parser.consume("Target voltage detected")
        parser.consume("Target Device ID (0x3027) is an Invalid Device ID. Please check your connections to the Target Device.")
        parser.consume("Operation Failed")
        #expect(parser.reportedDeviceID == 0x3027)
        #expect(PICDevice.identify(deviceID: 0x3027) == .pic16lf1459)
        #expect(parser.hint?.contains("PIC16LF1459") == true)
        #expect(!parser.succeeded(exitCode: 0, operation: .readDeviceID))
    }

    /// Real MPLAB X v6.20 output the first time a freshly reverted PICkit 3 is used.
    @Test func recognisesProgrammerFirmwareDownload() {
        let transcript = """
        Connecting to MPLAB PICkit 3...
        Currently loaded firmware on PICkit 3
        Firmware Suite Version.....01.26.56 *
        Firmware type..............Unknown Firmware Type
        Now Downloading new Firmware for target device: PIC16F1459
        Downloading RS...
        RS download complete
        Programming download...
        Downloading AP...
        AP download complete
        Programming download...
        Currently loaded firmware on PICkit 3
        Firmware Suite Version.....01.56.09
        Firmware type..............Enhanced Midrange
        Target voltage detected
        Target device PIC16LF1459 found.
        Device Revision ID = 1006
        Operation Succeeded
        """
        var parser = IPEOutputParser()
        for line in transcript.split(separator: "\n") { parser.consume(String(line)) }
        #expect(parser.loadingToolFirmware)
        #expect(parser.toolFirmwareVersion == "01.56.09")
        #expect(parser.stage == .connecting) // "Programming download..." is not the Program step
        #expect(parser.detectedTargetDevice == "PIC16LF1459")
        #expect(parser.succeeded(exitCode: 0, operation: .readDeviceID))
    }

    @Test func programWithoutVerifyMessageIsNotAPass() {
        var parser = IPEOutputParser()
        parser.consume("Program Succeeded.")
        parser.consume("Operation Succeeded")
        #expect(parser.succeeded(exitCode: 0, operation: .program(verify: false)))
        #expect(!parser.succeeded(exitCode: 0, operation: .program(verify: true)))
    }

    /// Real output from MPLAB X v6.35 when the PIC16F1xxxx pack is not installed (exit code 36).
    @Test func explainsMissingDevicePack() {
        var parser = IPEOutputParser()
        parser.consume("[2026-10-11 13:34:26.501] [info] [MplabLibusbController.cpp:192] LibUSBAccess version: 3.51.4")
        parser.consume("Could not find device:PIC16F1459")
        parser.consume("Please install the required pack by using the Pack Manager in MPLABX IDE/IPE.")
        #expect(!parser.succeeded(exitCode: 36, operation: .readDeviceID))
        #expect(parser.failureSummary(exitCode: 36, operation: .readDeviceID) == "Could not find device:PIC16F1459")
        #expect(parser.hint?.contains("PIC16F1xxxx_DFP") == true)
    }

    @Test func explainsMissingTargetPower() {
        var parser = IPEOutputParser()
        parser.consume("Target device was not found (could not detect target voltage VDD). You must connect to a target device to use PICkit 3.")
        #expect(parser.hint?.contains("Power the RFGEN44") == true)
    }
}

@Suite struct ProcessRunnerTests {
    private func run(_ arguments: [String], environment: [String: String] = [:]) async throws -> (lines: [String], exit: Int32, parser: IPEOutputParser) {
        var lines: [String] = []
        var exit: Int32 = -1
        var parser = IPEOutputParser()
        let events = ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [fakeIPECmd.path] + arguments,
            environment: environment.merging(["FAKE_IPECMD_DELAY": "0"]) { a, _ in a }
        )
        for try await event in events {
            switch event {
            case let .output(line): lines.append(line); parser.consume(line)
            case let .exited(code): exit = code
            }
        }
        return (lines, exit, parser)
    }

    @Test func programVerifyAndReadBackThroughFakeIPECmd() async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let device = work.appendingPathComponent("device.hex").path
        let invocation = IPEInvocation(tool: .pickit3, part: "16F1459", hexFilePath: firmwarePath)

        let program = try await run(invocation.arguments(for: .program(verify: true)), environment: ["FAKE_IPECMD_DEVICE": device])
        #expect(program.exit == 0)
        #expect(program.parser.succeeded(exitCode: program.exit, operation: .program(verify: true)))

        let readbackPath = work.appendingPathComponent("readback.hex").path
        let read = try await run(invocation.arguments(for: .readToHexFile(readbackPath)), environment: ["FAKE_IPECMD_DEVICE": device])
        #expect(read.exit == 0)
        let report = ReadbackVerifier.compare(
            expected: try IntelHex(contentsOf: URL(fileURLWithPath: firmwarePath)),
            readback: try IntelHex(contentsOf: URL(fileURLWithPath: readbackPath)),
            device: .pic16f1459
        )
        #expect(report.passed)

        let failing = try await run(invocation.arguments(for: .verify), environment: ["FAKE_IPECMD_DEVICE": device, "FAKE_IPECMD_FAIL": "verify"])
        #expect(failing.exit != 0)
        #expect(!failing.parser.succeeded(exitCode: failing.exit, operation: .verify))
    }

    @Test func cancellingStopsTheProcess() async throws {
        let started = ContinuousClock.now
        let task = Task {
            for try await _ in ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"]) {}
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        _ = await task.result
        #expect(ContinuousClock.now - started < .seconds(5))
    }
}
