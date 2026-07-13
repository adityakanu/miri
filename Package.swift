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
        .executable(name: "Miri", targets: ["MiriApp"]),
    ],
    targets: [
        .target(name: "MiriIPC"),
        .target(name: "MiriCore", dependencies: ["MiriIPC"]),
        .executableTarget(name: "MiriCLI", dependencies: ["MiriCore"]),
        .executableTarget(name: "MiriMCP", dependencies: ["MiriCore"]),
        .executableTarget(name: "MiriApp", dependencies: ["MiriCore"]),
        .testTarget(name: "MiriIPCTests", dependencies: ["MiriIPC"], resources: [.copy("Fixtures")]),
        .testTarget(name: "MiriCoreTests", dependencies: ["MiriCore"]),
    ]
)
