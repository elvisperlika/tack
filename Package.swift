// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "swift-executable",
    platforms: [.macOS(.v14)],  // CADisplayLink for vsync-synced note tracking
    targets: [
        .executableTarget(
            name: "swift-executable",
            // Explicit because sources now live in subfolders of Sources/, not directly under it,
            // so SwiftPM's single-target auto-detection no longer applies. Subfolders are compiled
            // recursively into the one target — they are not separate targets.
            path: "Sources",
            // ponytail: AppKit is main-thread; skip Swift 6 strict-concurrency ceremony
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
