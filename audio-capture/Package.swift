// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "transcriptor-audio",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "transcriptor-audio",
            path: "Sources"
        )
    ]
)
