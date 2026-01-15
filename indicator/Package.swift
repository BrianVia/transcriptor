// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "transcriptor-indicator",
    platforms: [.macOS(.v13)],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "transcriptor-indicator",
            path: "Sources",
            linkerSettings: [
                .linkedFramework("EventKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox")
            ]
        )
    ]
)
