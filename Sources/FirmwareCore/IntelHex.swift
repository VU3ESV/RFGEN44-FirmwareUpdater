import Foundation

/// A parsed Intel HEX file held as a sparse byte image keyed by absolute byte address.
public struct IntelHex: Sendable, Equatable {
    public struct ParseError: Error, LocalizedError, Equatable, Sendable {
        public let line: Int
        public let reason: String

        public init(line: Int, reason: String) {
            self.line = line
            self.reason = reason
        }

        public var errorDescription: String? { "Line \(line): \(reason)" }
    }

    public private(set) var bytes: [UInt32: UInt8] = [:]
    public private(set) var dataRecordCount = 0

    public init() {}

    public init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .ascii) ?? String(data: data, encoding: .utf8) else {
            throw ParseError(line: 0, reason: "File is not a text file")
        }
        try self.init(text: text)
    }

    public init(text: String) throws {
        var baseAddress: UInt32 = 0
        var sawEndOfFile = false

        for (index, rawLine) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let lineNumber = index + 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if sawEndOfFile { break }

            guard line.first == ":" else {
                throw ParseError(line: lineNumber, reason: "Record does not start with ':'")
            }
            let record = try Self.decodeHexBytes(line.dropFirst(), line: lineNumber)
            guard record.count >= 5 else {
                throw ParseError(line: lineNumber, reason: "Record is too short")
            }
            let length = Int(record[0])
            guard record.count == length + 5 else {
                throw ParseError(line: lineNumber, reason: "Byte count \(length) does not match record length")
            }
            guard record.reduce(UInt8(0), &+) == 0 else {
                throw ParseError(line: lineNumber, reason: "Checksum mismatch")
            }

            let offset = UInt32(record[1]) << 8 | UInt32(record[2])
            let payload = record[4..<(4 + length)]

            switch record[3] {
            case 0x00:
                for (i, byte) in payload.enumerated() {
                    let address = baseAddress &+ offset &+ UInt32(i)
                    if let existing = bytes[address], existing != byte {
                        throw ParseError(
                            line: lineNumber,
                            reason: String(format: "Conflicting data at address 0x%X", address)
                        )
                    }
                    bytes[address] = byte
                }
                dataRecordCount += 1
            case 0x01:
                sawEndOfFile = true
            case 0x02:
                guard length == 2 else { throw ParseError(line: lineNumber, reason: "Bad extended segment address record") }
                baseAddress = (UInt32(payload.first!) << 8 | UInt32(payload.last!)) << 4
            case 0x04:
                guard length == 2 else { throw ParseError(line: lineNumber, reason: "Bad extended linear address record") }
                baseAddress = (UInt32(payload.first!) << 8 | UInt32(payload.last!)) << 16
            case 0x03, 0x05:
                break // Start address records carry no memory contents.
            default:
                throw ParseError(line: lineNumber, reason: String(format: "Unsupported record type 0x%02X", record[3]))
            }
        }

        guard sawEndOfFile else { throw ParseError(line: 0, reason: "Missing end-of-file record") }
        guard !bytes.isEmpty else { throw ParseError(line: 0, reason: "File contains no data") }
    }

    private static func decodeHexBytes(_ text: Substring, line: Int) throws -> [UInt8] {
        let utf8 = Array(text.utf8)
        guard utf8.count.isMultiple(of: 2) else {
            throw ParseError(line: line, reason: "Odd number of hex digits")
        }
        var result = [UInt8]()
        result.reserveCapacity(utf8.count / 2)
        var i = 0
        while i < utf8.count {
            guard let hi = hexValue(utf8[i]), let lo = hexValue(utf8[i + 1]) else {
                throw ParseError(line: line, reason: "Invalid hex digit")
            }
            result.append(hi << 4 | lo)
            i += 2
        }
        return result
    }

    private static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): c - UInt8(ascii: "0")
        case UInt8(ascii: "A")...UInt8(ascii: "F"): c - UInt8(ascii: "A") + 10
        case UInt8(ascii: "a")...UInt8(ascii: "f"): c - UInt8(ascii: "a") + 10
        default: nil
        }
    }

    /// Contiguous byte-address ranges present in the file, in ascending order.
    public var addressRanges: [ClosedRange<UInt32>] {
        var ranges: [ClosedRange<UInt32>] = []
        for address in bytes.keys.sorted() {
            if let last = ranges.last, last.upperBound &+ 1 == address {
                ranges[ranges.count - 1] = last.lowerBound...address
            } else {
                ranges.append(address...address)
            }
        }
        return ranges
    }

    /// Word addresses (byte address / 2) that have at least one byte present.
    public var wordAddresses: [UInt32] {
        Array(Set(bytes.keys.map { $0 / 2 })).sorted()
    }

    /// Little-endian 16-bit word at a word address, as used by PIC10/12/16 hex files.
    /// A missing half of a word reads as 0xFF (erased). Returns nil when neither byte is present.
    public func word(at wordAddress: UInt32) -> UInt16? {
        let lo = bytes[wordAddress * 2]
        let hi = bytes[wordAddress * 2 + 1]
        if lo == nil && hi == nil { return nil }
        return UInt16(hi ?? 0xFF) << 8 | UInt16(lo ?? 0xFF)
    }
}
