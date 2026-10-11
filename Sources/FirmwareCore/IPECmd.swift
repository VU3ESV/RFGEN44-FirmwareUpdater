import Foundation

/// An installed copy of Microchip's MPLAB IPE command-line tool.
///
/// It is always started through Microchip's `ipecmd.sh` wrapper: the jar needs the classpath,
/// bundled JRE and environment that the wrapper's `common-vars.sh` sets up. The wrapper passes
/// `$@` unquoted, so callers must keep spaces out of every argument.
public struct IPECmdInstallation: Sendable, Hashable {
    public let script: URL
    /// MPLAB X version folder name, e.g. "v6.20".
    public let version: String?

    public init(script: URL, version: String?) {
        self.script = script
        self.version = version
    }

    public var executableURL: URL { URL(fileURLWithPath: "/bin/bash") }

    public func processArguments(_ ipecmdArguments: [String]) -> [String] {
        [script.path] + ipecmdArguments
    }

    public var displayPath: String { script.path }

    /// "v6.20" → [6, 20]
    public var versionNumbers: [Int]? {
        guard let version, let match = version.firstMatch(of: /(\d+)\.(\d+)/) else { return nil }
        return [Int(match.1)!, Int(match.2)!]
    }

    /// False when this MPLAB release is known to have dropped the tool. Unknown versions are given the benefit of the doubt.
    public func supports(_ tool: ProgrammerKind) -> Bool {
        guard let last = tool.lastSupportedMPLABVersion, let mine = versionNumbers else { return true }
        return !last.lexicographicallyPrecedes(mine)
    }
}

public enum IPECmdLocator {
    public static let defaultRoots: [URL] = [
        URL(fileURLWithPath: "/Applications/microchip/mplabx"),
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications/microchip/mplabx"),
        URL(fileURLWithPath: "/opt/microchip/mplabx"),
    ]

    /// All MPLAB X / IPE installations found, newest version first.
    public static func locateAll(roots: [URL] = defaultRoots) -> [IPECmdInstallation] {
        let fm = FileManager.default
        var found: [IPECmdInstallation] = []
        for root in roots {
            guard let versions = try? fm.contentsOfDirectory(atPath: root.path) else { continue }
            let sorted = versions.filter { $0.hasPrefix("v") }
                .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            for version in sorted {
                if let script = script(inMPLABXFolder: root.appendingPathComponent(version)) {
                    found.append(IPECmdInstallation(script: script, version: version))
                }
            }
        }
        return found
    }

    /// Builds an installation from what the user picked: ipecmd.sh, ipecmd.jar (its wrapper is used),
    /// or an MPLAB X version folder.
    public static func installation(forUserSelection url: URL) -> IPECmdInstallation? {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        let version = url.pathComponents.last { $0.range(of: #"^v\d+\.\d+"#, options: .regularExpression) != nil }

        let script: URL?
        if isDirectory.boolValue {
            script = self.script(inMPLABXFolder: url)
        } else if url.pathExtension == "jar" {
            script = [url.deletingLastPathComponent().appendingPathComponent("bin/ipecmd.sh"),
                      url.deletingLastPathComponent().appendingPathComponent("ipecmd.sh")]
                .first { fm.fileExists(atPath: $0.path) }
        } else {
            script = url
        }
        return script.map { IPECmdInstallation(script: $0, version: version) }
    }

    /// macOS keeps the wrapper in `mplab_ipe/bin/`, Linux directly in `mplab_ipe/`.
    static func script(inMPLABXFolder folder: URL) -> URL? {
        let ipeFolder = folder.appendingPathComponent("mplab_platform/mplab_ipe")
        return [ipeFolder.appendingPathComponent("bin/ipecmd.sh"), ipeFolder.appendingPathComponent("ipecmd.sh")]
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

/// One ipecmd run: which tool, which part, which file, and what to do.
public struct IPEInvocation: Sendable, Equatable {
    public enum Operation: Sendable, Equatable {
        /// Program the whole device. With a PICkit 3 programming already verifies as it writes;
        /// `verify` adds ipecmd's separate verify pass, which fails on code-protected firmware.
        case program(verify: Bool)
        case verify
        case readDeviceID
        case readToHexFile(String)
        case erase
        case blankCheck
    }

    public var tool: ProgrammerKind
    public var toolSerialNumber: String?
    public var part: String
    public var hexFilePath: String?
    /// Supply the target from the programmer at this voltage; nil when the target has its own supply.
    public var powerTargetVoltage: Double?

    public init(tool: ProgrammerKind, toolSerialNumber: String? = nil, part: String, hexFilePath: String? = nil, powerTargetVoltage: Double? = nil) {
        self.tool = tool
        self.toolSerialNumber = toolSerialNumber
        self.part = part
        self.hexFilePath = hexFilePath
        self.powerTargetVoltage = powerTargetVoltage
    }

    public func arguments(for operation: Operation) -> [String] {
        var args = ["-TP\(tool.ipecmdToolCode)"]
        if let serial = toolSerialNumber, !serial.isEmpty { args.append("-TS\(serial)") }
        args.append("-P\(part)")
        if let voltage = powerTargetVoltage { args.append(String(format: "-W%.1f", voltage)) }

        switch operation {
        case let .program(verify):
            args += hexArgument + ["-M"] + (verify ? ["-Y"] : [])
        case .verify:
            args += hexArgument + ["-Y"]
        case .readDeviceID:
            args.append("-I")
        case let .readToHexFile(path):
            args.append("-GF\(path)")
        case .erase:
            args.append("-E")
        case .blankCheck:
            args.append("-C")
        }
        // ipecmd holds the target in reset by default; let it run once the tool is done.
        args.append("-OL")
        return args
    }

    private var hexArgument: [String] {
        hexFilePath.map { ["-F\($0)"] } ?? []
    }
}
