import Foundation

/// Memory map of a 14-bit enhanced mid-range PIC as it appears in a hex file
/// (hex byte address = word address × 2).
public struct PICDevice: Sendable, Hashable, Identifiable {
    public struct ConfigWord: Sendable, Hashable {
        public let name: String
        public let wordAddress: UInt32
        /// Bits that are implemented; unimplemented bits are ignored when comparing.
        public let implementedMask: UInt16
    }

    /// A single configuration bit, e.g. CP or LVP.
    public struct ConfigBit: Sendable, Hashable {
        public let wordAddress: UInt32
        public let bit: Int
        public let activeLow: Bool

        public func isEnabled(in value: UInt16) -> Bool {
            let set = value & (1 << bit) != 0
            return activeLow ? !set : set
        }
    }

    public enum Region: String, Sendable {
        case program = "Program memory"
        case userID = "User ID"
        case config = "Configuration"
        case other = "Outside device memory"
    }

    public let name: String
    /// Value the chip reports at word 0x8006 (DEVID), from Microchip's device pack.
    public let deviceID: UInt16
    public let programWords: UInt32
    public let userIDWords: ClosedRange<UInt32>
    public let configWords: [ConfigWord]
    public let codeProtect: ConfigBit?
    public let lowVoltageProgramming: ConfigBit?

    public var id: String { name }
    public var wordMask: UInt16 { 0x3FFF }
    public var erasedWord: UInt16 { 0x3FFF }

    /// Part name in the form ipecmd's `-P` option expects ("16F1459").
    public var ipecmdPartName: String {
        name.uppercased().hasPrefix("PIC") ? String(name.dropFirst(3)) : name
    }

    /// F and LF versions of a part (e.g. PIC16F1459 / PIC16LF1459) take the same firmware;
    /// they differ only in supply voltage.
    public func isVariant(of other: PICDevice) -> Bool {
        name.uppercased().replacingOccurrences(of: "LF", with: "F") == other.name.uppercased().replacingOccurrences(of: "LF", with: "F")
    }

    public func region(ofWord address: UInt32) -> Region {
        if address < programWords { return .program }
        if userIDWords.contains(address) { return .userID }
        if configWords.contains(where: { $0.wordAddress == address }) { return .config }
        return .other
    }
}

extension PICDevice {
    /// PIC16(L)F1454/1455/1459 share one memory map: 8K words of flash, user IDs at
    /// 0x8000–0x8003 and two configuration words at 0x8007–0x8008 (masks from PIC12-16F1xxx_DFP).
    private static func usbFamily(_ name: String, deviceID: UInt16) -> PICDevice {
        PICDevice(
            name: name,
            deviceID: deviceID,
            programWords: 0x2000,
            userIDWords: 0x8000...0x8003,
            configWords: [
                ConfigWord(name: "CONFIG1", wordAddress: 0x8007, implementedMask: 0x3EFF),
                ConfigWord(name: "CONFIG2", wordAddress: 0x8008, implementedMask: 0x3FF3),
            ],
            codeProtect: ConfigBit(wordAddress: 0x8007, bit: 7, activeLow: true),
            lowVoltageProgramming: ConfigBit(wordAddress: 0x8008, bit: 13, activeLow: false)
        )
    }

    public static let pic16f1459 = usbFamily("PIC16F1459", deviceID: 0x3023)
    public static let pic16lf1459 = usbFamily("PIC16LF1459", deviceID: 0x3027)

    public static let supported: [PICDevice] = [
        pic16f1459,
        pic16lf1459,
        usbFamily("PIC16F1455", deviceID: 0x3021),
        usbFamily("PIC16LF1455", deviceID: 0x3025),
        usbFamily("PIC16F1454", deviceID: 0x3020),
        usbFamily("PIC16LF1454", deviceID: 0x3024),
    ]

    /// The supported part with this DEVID, e.g. 0x3027 → PIC16LF1459.
    public static func identify(deviceID: UInt16) -> PICDevice? {
        supported.first { $0.deviceID == deviceID & 0x3FFF }
    }

    /// Picks the device named in a firmware file name such as "USB_IO_BOARD_V3_pic16f1459.V2.hex".
    public static func guess(fromFileName fileName: String) -> PICDevice? {
        let lowered = fileName.lowercased()
        return supported
            .filter { lowered.contains($0.ipecmdPartName.lowercased()) }
            .max { $0.name.count < $1.name.count }
    }
}

/// What a hex file will put into a particular device.
public struct FirmwareSummary: Sendable, Equatable {
    public struct ConfigValue: Sendable, Equatable {
        public let word: PICDevice.ConfigWord
        public let value: UInt16?
    }

    public let device: PICDevice
    /// Program-memory words that are not blank (0x3FFF).
    public let programWordsUsed: Int
    public let highestProgramAddress: UInt32?
    public let configValues: [ConfigValue]
    public let userIDs: [UInt16?]
    public let outOfRangeWordAddresses: [UInt32]

    public init(hex: IntelHex, device: PICDevice) {
        self.device = device
        var used = 0
        var highest: UInt32?
        var outOfRange: [UInt32] = []
        for address in hex.wordAddresses {
            switch device.region(ofWord: address) {
            case .program:
                if let word = hex.word(at: address), word & device.wordMask != device.erasedWord {
                    used += 1
                    highest = max(highest ?? 0, address)
                }
            case .other:
                outOfRange.append(address)
            case .userID, .config:
                break
            }
        }
        programWordsUsed = used
        highestProgramAddress = highest
        outOfRangeWordAddresses = outOfRange
        configValues = device.configWords.map { ConfigValue(word: $0, value: hex.word(at: $0.wordAddress)) }
        userIDs = device.userIDWords.map { hex.word(at: $0) }
    }

    public var fitsDevice: Bool { outOfRangeWordAddresses.isEmpty }
    public var hasConfiguration: Bool { configValues.contains { $0.value != nil } }

    public var codeProtectionEnabled: Bool? { flag(device.codeProtect) }
    public var lowVoltageProgrammingEnabled: Bool? { flag(device.lowVoltageProgramming) }

    private func flag(_ bit: PICDevice.ConfigBit?) -> Bool? {
        guard let bit,
              let value = configValues.first(where: { $0.word.wordAddress == bit.wordAddress })?.value
        else { return nil }
        return bit.isEnabled(in: value)
    }
}
