// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeSweep",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "ClaudeSweep", targets: ["ClaudeSweep"])],
    targets: [
        .target(name: "SweepCore"),
        .executableTarget(name: "ClaudeSweep", dependencies: ["SweepCore"]),
        .testTarget(name: "SweepCoreTests", dependencies: ["SweepCore"]),
        .testTarget(name: "MacIntegrationTests", dependencies: ["ClaudeSweep", "SweepCore"])
    ]
)
