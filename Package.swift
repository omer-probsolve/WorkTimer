// swift-tools-version: 5.9
import PackageDescription

var products: [Product] = [.executable(name: "WorkTimerCollector", targets: ["WorkTimerCollector"])]
var targets: [Target] = [
    .target(name: "WorkTimerCore", path: "Sources/WorkTimerCore"),
    .target(name: "WorkTimerWindows", path: "Sources/WorkTimerWindows", linkerSettings: [
        .linkedLibrary("winhttp", .when(platforms: [.windows])),
        .linkedLibrary("crypt32", .when(platforms: [.windows])),
        .linkedLibrary("iphlpapi", .when(platforms: [.windows])),
        .linkedLibrary("ws2_32", .when(platforms: [.windows])),
        .linkedLibrary("dnsapi", .when(platforms: [.windows])),
    ]),
    .executableTarget(name: "WorkTimerCollector", dependencies: ["WorkTimerCore", "WorkTimerWindows"]),
    .testTarget(name: "WorkTimerCoreTests", dependencies: ["WorkTimerCore"], path: "Tests/WorkTimerCoreTests"),
]
#if os(macOS)
products += [.library(name: "WorkTimerKit", targets: ["WorkTimerKit"]),
             .executable(name: "WorkTimer", targets: ["WorkTimer"])]
targets += [.target(name: "WorkTimerKit", dependencies: ["WorkTimerCore"], path: "Sources/WorkTimer"),
            .executableTarget(name: "WorkTimer", dependencies: ["WorkTimerKit"], path: "Sources/WorkTimerApp"),
            .testTarget(name: "WorkTimerLANTests", dependencies: ["WorkTimerKit", "WorkTimerCore"])]
#endif

let package = Package(
    name: "WorkTimer",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
