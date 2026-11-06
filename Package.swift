// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "lidwake",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "lidwake", targets: ["lidwake"]),
        .library(name: "LidwakeCore", targets: ["LidwakeCore"]),
    ],
    targets: [
        .target(
            name: "LidwakeCore",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(name: "lidwake", dependencies: ["LidwakeCore"]),
        .testTarget(name: "LidwakeCoreTests", dependencies: ["LidwakeCore"]),
    ]
)
