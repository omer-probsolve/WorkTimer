// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WorkTimer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "WorkTimer",
            path: "Sources/WorkTimer"
        )
    ]
)
