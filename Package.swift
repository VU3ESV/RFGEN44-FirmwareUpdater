// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RFGEN44FirmwareUpdater",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "RFGEN44Updater", targets: ["RFGEN44Updater"])
    ],
    targets: [
        .target(name: "FirmwareCore"),
        .executableTarget(
            name: "RFGEN44Updater",
            dependencies: ["FirmwareCore"],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .testTarget(name: "FirmwareCoreTests", dependencies: ["FirmwareCore"], exclude: ["Fixtures"]),
    ]
)
