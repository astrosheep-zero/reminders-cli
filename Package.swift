// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RemindersPOC",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "reminder", targets: ["ReminderCLI"])],
    targets: [
        .target(name: "ReminderCore"),
        .target(name: "RuntimeShim", publicHeadersPath: "include"),
        .target(name: "ReminderRuntime", dependencies: ["RuntimeShim"]),
        .target(name: "ReminderKitShim", publicHeadersPath: "include"),
        .target(name: "ReminderNative", dependencies: ["ReminderCore", "ReminderKitShim"]),
        .executableTarget(name: "ReminderCLI", dependencies: ["ReminderCore", "ReminderRuntime", "ReminderNative"]),
        .testTarget(name: "ReminderCoreTests", dependencies: ["ReminderCore"]),
        .testTarget(name: "ReminderRuntimeTests", dependencies: ["ReminderRuntime"]),
        .testTarget(name: "ReminderNativeTests", dependencies: ["ReminderNative", "ReminderCore"]),
        .testTarget(name: "ReminderCLITests", dependencies: ["ReminderCLI", "ReminderCore", "ReminderRuntime"])
    ]
)
