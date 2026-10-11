import Foundation

/// Result of comparing a firmware image against memory read back from the device.
public struct VerificationReport: Sendable, Equatable {
    public struct Mismatch: Sendable, Equatable, Identifiable {
        public let wordAddress: UInt32
        public let region: PICDevice.Region
        public let expected: UInt16
        public let actual: UInt16

        public var id: UInt32 { wordAddress }
    }

    public var programWordsCompared = 0
    public var userIDWordsCompared = 0
    public var configWordsCompared = 0
    public var mismatches: [Mismatch] = []
    /// False when the read-back file held no program memory at all.
    public var readbackContainsProgramMemory = true
    /// Every program word read back as 0x0000, which is what a code-protected device returns.
    public var looksCodeProtected = false

    public var passed: Bool { readbackContainsProgramMemory && mismatches.isEmpty }
    public var wordsCompared: Int { programWordsCompared + userIDWordsCompared + configWordsCompared }
}

public enum ReadbackVerifier {
    /// Compares every program-memory word (blank words must read back blank) plus the
    /// user ID and configuration words the firmware defines.
    public static func compare(expected: IntelHex, readback: IntelHex, device: PICDevice) -> VerificationReport {
        var report = VerificationReport()
        let mask = device.wordMask

        let readbackProgramWords = readback.wordAddresses.filter { device.region(ofWord: $0) == .program }
        guard !readbackProgramWords.isEmpty else {
            report.readbackContainsProgramMemory = false
            return report
        }

        var allZero = true
        for address in 0..<device.programWords {
            let want = (expected.word(at: address) ?? device.erasedWord) & mask
            // Hex exporters may omit blank areas, so a missing word reads as erased.
            let got = (readback.word(at: address) ?? device.erasedWord) & mask
            if got != 0 { allZero = false }
            report.programWordsCompared += 1
            if want != got {
                report.mismatches.append(.init(wordAddress: address, region: .program, expected: want, actual: got))
            }
        }
        report.looksCodeProtected = allZero

        for address in device.userIDWords {
            guard let want = expected.word(at: address) else { continue }
            let got = readback.word(at: address) ?? device.erasedWord
            report.userIDWordsCompared += 1
            if want & mask != got & mask {
                report.mismatches.append(.init(wordAddress: address, region: .userID, expected: want & mask, actual: got & mask))
            }
        }

        for config in device.configWords {
            guard let want = expected.word(at: config.wordAddress) else { continue }
            let got = readback.word(at: config.wordAddress) ?? device.erasedWord
            report.configWordsCompared += 1
            if want & config.implementedMask != got & config.implementedMask {
                report.mismatches.append(.init(
                    wordAddress: config.wordAddress,
                    region: .config,
                    expected: want & config.implementedMask,
                    actual: got & config.implementedMask
                ))
            }
        }

        return report
    }
}
