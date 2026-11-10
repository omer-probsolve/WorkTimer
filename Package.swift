// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WorkTimer",
    platforms: [.macOS(.v14)],
    products: [
        // The whole macOS app as a library, so a launcher (Toolbelt) can host it.
        .library(name: "WorkTimerKit", targets: ["WorkTimerKit"]),
        .executable(name: "WorkTimer", targets: ["WorkTimer"]),
    ],
    targets: [
        // Platform-free logic: sessions, agent transcripts, totals and formatting.
        // Foundation only, so other platforms' apps can share it.
        .target(
            name: "WorkTimerCore",
            path: "Sources/WorkTimerCore"
        ),
        // The macOS app: menu bar item, windows, tracking. `WorkTimerController` is
        // its entry point, used by the standalone app below and by hosts.
        .target(
            name: "WorkTimerKit",
            dependencies: ["WorkTimerCore"],
            path: "Sources/WorkTimer"
        ),
        // The standalone "Work Timer.app": just starts the controller.
        .executableTarget(
            name: "WorkTimer",
            dependencies: ["WorkTimerKit"],
            path: "Sources/WorkTimerApp"
        ),
        .testTarget(
            name: "WorkTimerCoreTests",
            dependencies: ["WorkTimerCore"],
            path: "Tests/WorkTimerCoreTests"
        ),
    ]
)
