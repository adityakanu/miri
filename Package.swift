// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Miri",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MiriCore", targets: ["MiriCore"]),
        .library(name: "MiriIPC", targets: ["MiriIPC"]),
        .executable(name: "miri", targets: ["MiriCLI"]),
        .executable(name: "miri-mcp", targets: ["MiriMCP"]),
        // Keep the development app product distinct from the `miri` CLI on
        // case-insensitive macOS filesystems. XcodeGen still packages Miri.app.
        .executable(name: "miri-app", targets: ["MiriApp"]),
    ],
    dependencies: [
        // On-device Parakeet ASR on the Apple Neural Engine. Apache-2.0.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.6"),
    ],
    targets: [
        .target(name: "MiriIPC"),
        .target(
            name: "MiriCore",
            dependencies: ["MiriIPC", .product(name: "FluidAudio", package: "FluidAudio")]
        ),
        .executableTarget(name: "MiriCLI", dependencies: ["MiriCore"]),
        .executableTarget(name: "MiriMCP", dependencies: ["MiriCore"]),
        .executableTarget(name: "MiriApp", dependencies: ["MiriCore"]),
        .testTarget(name: "MiriIPCTests", dependencies: ["MiriIPC"], resources: [.copy("Fixtures")]),
        .testTarget(name: "MiriCoreTests", dependencies: ["MiriCore"]),
    ]
)
