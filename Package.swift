// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SystemMonitor",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SystemMonitorCore", targets: ["SystemMonitorCore"]),
        .executable(name: "drivemon", targets: ["drivemon"]),
        .executable(name: "SystemMonitorApp", targets: ["SystemMonitorApp"]),
        .executable(name: "lanes-verify", targets: ["verify"]),
    ],
    targets: [
        .target(
            name: "CPower",
            linkerSettings: [
                .linkedLibrary("IOReport"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .executableTarget(
            name: "powermon",
            dependencies: ["CPower", "SystemMonitorCore"]
        ),
        .target(
            name: "SystemMonitorCore",
            dependencies: ["CPower"],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("DiskArbitration"),
            ]
        ),
        .executableTarget(
            name: "drivemon",
            dependencies: ["SystemMonitorCore"]
        ),
        .executableTarget(
            name: "SystemMonitorApp",
            dependencies: ["SystemMonitorCore"]
        ),
        .executableTarget(
            name: "verify",
            dependencies: ["SystemMonitorCore"]
        ),
        .testTarget(
            name: "SystemMonitorCoreTests",
            dependencies: ["SystemMonitorCore", "CPower"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
