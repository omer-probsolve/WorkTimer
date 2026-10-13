// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WorkTimer",
    platforms: [.macOS(.v14)],
    targets: [
        // Platform-free logic: sessions, agent transcripts, totals and formatting.
        // Foundation only, so other platforms' apps can share it.
        .target(
            name: "WorkTimerCore",
            path: "Sources/WorkTimerCore"
        ),
        // The macOS menu bar app.
        .executableTarget(
            name: "WorkTimer",
            dependencies: ["WorkTimerCore"],
            path: "Sources/WorkTimer"
        ),
        .testTarget(
            name: "WorkTimerCoreTests",
            dependencies: ["WorkTimerCore"],
            path: "Tests/WorkTimerCoreTests"
        ),
    ]
)
