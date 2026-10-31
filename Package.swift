// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RemindersPOC",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "reminder", targets: ["ReminderCLI"])],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        // NIO permits newer Collections releases that require Swift 6.4; retain our 6.2 floor.
        .package(url: "https://github.com/apple/swift-collections.git", exact: "1.6.0")
    ],
    targets: [
        .target(name: "ReminderCore"),
        .target(name: "RuntimeShim", publicHeadersPath: "include"),
        .target(name: "ReminderRuntime", dependencies: ["RuntimeShim"]),
        .target(name: "ReminderKitShim", publicHeadersPath: "include"),
        .target(name: "ReminderNative", dependencies: ["ReminderCore", "ReminderKitShim"]),
        .target(name: "ReminderFacade", dependencies: ["ReminderCore", "ReminderRuntime"]),
        .target(name: "ReminderMCP", dependencies: ["ReminderFacade", .product(name: "MCP", package: "swift-sdk")]),
        .executableTarget(name: "ReminderCLI", dependencies: ["ReminderFacade", "ReminderMCP", "ReminderNative"]),
        .testTarget(name: "ReminderCoreTests", dependencies: ["ReminderCore"]),
        .testTarget(name: "ReminderRuntimeTests", dependencies: ["ReminderRuntime"]),
        .testTarget(name: "ReminderNativeTests", dependencies: ["ReminderNative", "ReminderCore"]),
        .testTarget(name: "ReminderCLITests", dependencies: ["ReminderCLI", "ReminderFacade", "ReminderMCP", "ReminderCore", "ReminderRuntime"])

    ]
)
