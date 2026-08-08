// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceInput",
    platforms: [.macOS(.v14)],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "VoiceInput",
            dependencies: [],
            path: "Sources/VoiceInput"
        )
    ]
)
