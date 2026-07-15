// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "swift-executable",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "swift-executable",
            // ponytail: AppKit is main-thread; skip Swift 6 strict-concurrency ceremony
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
