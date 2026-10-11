import Foundation
import Testing
@testable import FirmwareCore

/// Synthetic PIC16F1459 image shaped like the RFGEN44 firmware: same first instructions,
/// configuration words and highest address, filler in between.
private let sampleFirmware = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Tests/FirmwareCoreTests/Fixtures/sample-pic16f1459.hex")

@Suite struct IntelHexTests {
    @Test func parsesSampleFirmware() throws {
        let hex = try IntelHex(contentsOf: sampleFirmware)
        #expect(hex.word(at: 0x0000) == 0x3180) // first record ":0400000080310A2819"
        #expect(hex.word(at: 0x0001) == 0x280A)
        #expect(hex.word(at: 0x8007) == 0x0FA4) // CONFIG1
        #expect(hex.word(at: 0x8008) == 0x1FCF) // CONFIG2
        #expect(hex.word(at: 0x8000) == 0x3FFF) // user ID
        #expect(hex.addressRanges.last == 0x1000E...0x10011)
    }

    @Test func summarisesSampleFirmwareForPIC16F1459() throws {
        let hex = try IntelHex(contentsOf: sampleFirmware)
        let summary = FirmwareSummary(hex: hex, device: .pic16f1459)
        #expect(summary.fitsDevice)
        #expect(summary.highestProgramAddress == 0x1F7F)
        #expect(summary.programWordsUsed > 7000)
        #expect(summary.codeProtectionEnabled == false)
        #expect(summary.lowVoltageProgrammingEnabled == false)
        #expect(summary.configValues.map(\.value) == [0x0FA4, 0x1FCF])
    }

    @Test func handlesExtendedLinearAddressAndCRLF() throws {
        let text = ":020000040001F9\r\n:04000E00A40FCF1F4D\r\n:00000001FF\r\n"
        let hex = try IntelHex(text: text)
        #expect(hex.bytes.count == 4)
        #expect(hex.word(at: 0x8007) == 0x0FA4)
    }

    @Test func rejectsBadChecksum() {
        #expect(throws: IntelHex.ParseError(line: 1, reason: "Checksum mismatch")) {
            try IntelHex(text: ":0400000080310A2818\n:00000001FF\n")
        }
    }

    @Test func rejectsMissingEOF() {
        #expect(throws: IntelHex.ParseError(line: 0, reason: "Missing end-of-file record")) {
            try IntelHex(text: ":0400000080310A2819\n")
        }
    }

    @Test func rejectsNonHexText() {
        #expect(throws: IntelHex.ParseError.self) {
            try IntelHex(text: "hello\n")
        }
    }

    @Test func guessesDeviceFromFileName() {
        #expect(PICDevice.guess(fromFileName: "USB_IO_BOARD_V3_pic16f1459.V2.hex")?.name == "PIC16F1459")
        #expect(PICDevice.guess(fromFileName: "board_PIC16LF1459.hex")?.name == "PIC16LF1459")
        #expect(PICDevice.guess(fromFileName: "firmware.hex") == nil)
        #expect(PICDevice.pic16f1459.ipecmdPartName == "16F1459")
        #expect(PICDevice.pic16lf1459.isVariant(of: .pic16f1459))
        #expect(!PICDevice.pic16lf1459.isVariant(of: PICDevice.supported.first { $0.name == "PIC16F1455" }!))
    }
}

@Suite struct ReadbackVerifierTests {
    private func image(_ words: [UInt32: UInt16]) -> IntelHex {
        var lines: [String] = []
        var upper: UInt32 = .max
        for (address, word) in words.sorted(by: { $0.key < $1.key }) {
            let byteAddress = address * 2
            if byteAddress >> 16 != upper {
                upper = byteAddress >> 16
                lines.append(record(type: 4, address: 0, data: [UInt8(upper >> 8), UInt8(upper & 0xFF)]))
            }
            lines.append(record(type: 0, address: UInt16(byteAddress & 0xFFFF), data: [UInt8(word & 0xFF), UInt8(word >> 8)]))
        }
        lines.append(":00000001FF")
        return try! IntelHex(text: lines.joined(separator: "\n"))
    }

    private func record(type: UInt8, address: UInt16, data: [UInt8]) -> String {
        let bytes = [UInt8(data.count), UInt8(address >> 8), UInt8(address & 0xFF), type] + data
        let checksum = UInt8(truncatingIfNeeded: 0 &- Int(bytes.reduce(UInt8(0), &+)))
        return ":" + (bytes + [checksum]).map { String(format: "%02X", $0) }.joined()
    }

    @Test func identicalImagesPass() throws {
        let hex = try IntelHex(contentsOf: sampleFirmware)
        let report = ReadbackVerifier.compare(expected: hex, readback: hex, device: .pic16f1459)
        #expect(report.passed)
        #expect(report.programWordsCompared == 0x2000)
        #expect(report.configWordsCompared == 2)
        #expect(report.userIDWordsCompared == 4)
    }

    @Test func detectsProgramMismatchAndIgnoresUnimplementedBits() {
        let expected = image([0x0000: 0x3180, 0x0001: 0x280A, 0x8007: 0x0FA4])
        // Word 1 differs; CONFIG1 differs only in unimplemented bit 8; top two bits are ignored.
        let readback = image([0x0000: 0xF180, 0x0001: 0x280B, 0x8007: 0x0EA4])
        let report = ReadbackVerifier.compare(expected: expected, readback: readback, device: .pic16f1459)
        #expect(report.mismatches.map(\.wordAddress) == [0x0001])
        #expect(!report.passed)
    }

    @Test func blankWordsMustReadBlank() {
        let expected = image([0x0000: 0x3180])
        let readback = image([0x0000: 0x3180, 0x0100: 0x0000])
        let report = ReadbackVerifier.compare(expected: expected, readback: readback, device: .pic16f1459)
        #expect(report.mismatches.first?.wordAddress == 0x0100)
    }

    @Test func emptyReadbackFails() {
        let expected = image([0x0000: 0x3180])
        let readback = image([0x8007: 0x0FA4])
        let report = ReadbackVerifier.compare(expected: expected, readback: readback, device: .pic16f1459)
        #expect(!report.readbackContainsProgramMemory)
        #expect(!report.passed)
    }

    @Test func flagsCodeProtectedReadback() {
        let expected = image([0x0000: 0x3180])
        var zeros: [UInt32: UInt16] = [:]
        for address in UInt32(0)..<0x2000 { zeros[address] = 0 }
        let report = ReadbackVerifier.compare(expected: expected, readback: image(zeros), device: .pic16f1459)
        #expect(report.looksCodeProtected)
        #expect(!report.passed)
    }
}
