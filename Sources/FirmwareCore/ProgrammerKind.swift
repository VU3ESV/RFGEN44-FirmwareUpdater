import Foundation

/// Microchip programmers that MPLAB IPE's `ipecmd` can drive, identified by USB product ID.
public enum ProgrammerKind: String, Sendable, CaseIterable, Identifiable {
    case pickit3
    case pickit4
    case pickit5
    case snap
    case icd3
    case icd4
    case icd5

    public static let microchipVendorID: UInt16 = 0x04D8

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .pickit3: "PICkit 3"
        case .pickit4: "PICkit 4"
        case .pickit5: "PICkit 5"
        case .snap: "MPLAB Snap"
        case .icd3: "MPLAB ICD 3"
        case .icd4: "MPLAB ICD 4"
        case .icd5: "MPLAB ICD 5"
        }
    }

    /// Value for ipecmd's `-TP` tool option.
    public var ipecmdToolCode: String {
        switch self {
        case .pickit3: "PK3"
        case .pickit4: "PK4"
        case .pickit5: "PK5"
        case .snap: "SNAP"
        case .icd3: "ICD3"
        case .icd4: "ICD4"
        case .icd5: "ICD5"
        }
    }

    /// Product IDs in normal (MPLAB) mode. Bootloader-mode IDs are deliberately absent.
    public var usbProductIDs: Set<UInt16> {
        switch self {
        case .pickit3: [0x900A]
        case .pickit4: [0x9012, 0x901B, 0x901D, 0x9028]
        case .pickit5: [0x9036]
        case .snap: [0x9018, 0x901C, 0x901E, 0x9029]
        case .icd3: [0x9009]
        case .icd4: [0x9015]
        case .icd5: [0x9038, 0x903F]
        }
    }

    /// Microchip dropped PICkit 3 and ICD 3 from MPLAB X / IPE starting with v6.25;
    /// v6.20 is the last release that can drive them.
    public var lastSupportedMPLABVersion: [Int]? {
        switch self {
        case .pickit3, .icd3: [6, 20]
        default: nil
        }
    }

    public init?(vendorID: UInt16, productID: UInt16) {
        guard vendorID == Self.microchipVendorID,
              let kind = Self.allCases.first(where: { $0.usbProductIDs.contains(productID) })
        else { return nil }
        self = kind
    }
}
