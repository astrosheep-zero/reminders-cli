import Foundation
import Testing
import Darwin

/// Compiles the real production frontend, injecting only a protocol fixture worker. No Native store/API.
struct InterruptionTests {
    @Test func frontendSubprocessInterruptTerminatesAndReapsWorker() throws {
        let fixture = try FrontendFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        for signalNumber in [SIGINT, SIGTERM] {
            for phase in ["before", "after"] {
                let artifact = fixture.directory.appendingPathComponent("\(signalNumber)-\(phase).pid")
                let process = Process(), output = Pipe()
                process.executableURL = fixture.executable; process.arguments = [artifact.path, phase]
                process.standardOutput = output; process.standardError = FileHandle.nullDevice
                try process.run()
                var workerPID: Int32?
                defer {
                    if process.isRunning {
                        if let workerPID { _ = kill(workerPID, SIGKILL) }
                        _ = kill(process.processIdentifier, SIGKILL)
                        process.waitUntilExit()
                    }
                }
                let readyDeadline = ProcessInfo.processInfo.systemUptime + 5
                while !FileManager.default.fileExists(atPath: artifact.path), process.isRunning,
                      ProcessInfo.processInfo.systemUptime < readyDeadline { Thread.sleep(forTimeInterval: 0.01) }
                workerPID = Int32(try String(contentsOf: artifact, encoding: .utf8))
                let pid = try #require(workerPID)
                #expect(kill(process.processIdentifier, signalNumber) == 0)
                let exitDeadline = ProcessInfo.processInfo.systemUptime + 5
                while process.isRunning, ProcessInfo.processInfo.systemUptime < exitDeadline { Thread.sleep(forTimeInterval: 0.01) }
                try #require(!process.isRunning, "Frontend must cancel/reap promptly, not wait for its 30-second deadline")
                process.waitUntilExit()
                #expect(process.terminationReason == .exit)
                #expect(process.terminationStatus == (phase == "after" ? 5 : 6))
                #expect(kill(pid, 0) == -1); #expect(errno == ESRCH, "Disclaimed worker must not be orphaned")
                let data = try output.fileHandleForReading.readToEnd() ?? Data()
                let text = String(decoding: data, as: UTF8.self)
                #expect(text.contains(phase == "after" ? "outcomeUnknown" : "cancelled"))
            }
        }
    }
}

private struct FrontendFixture {
    let directory: URL
    let executable: URL
    init() throws {
        let manager = FileManager.default
        directory = manager.temporaryDirectory.appendingPathComponent("cli-interrupt-\(UUID())")
        executable = directory.appendingPathComponent("fixture-frontend")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sourceRoot = root.appendingPathComponent("Sources")
        let shim = sourceRoot.appendingPathComponent("RuntimeShim")
        let moduleMap = directory.appendingPathComponent("module.modulemap")
        try "module RuntimeShim { header \"\(shim.path)/include/RuntimeShim.h\" export * }".write(to: moduleMap, atomically: true, encoding: .utf8)
        let source = directory.appendingPathComponent("main.swift")
        try frontendFixtureSource.write(to: source, atomically: true, encoding: .utf8)
        let imports = ["-I", directory.path, "-Xcc", "-fmodule-map-file=\(moduleMap.path)"]
        func files(_ target: String) throws -> [String] {
            try manager.contentsOfDirectory(atPath: sourceRoot.appendingPathComponent(target).path)
                .filter { $0.hasSuffix(".swift") && $0 != "main.swift" }
                .map { sourceRoot.appendingPathComponent(target + "/" + $0).path }
        }
        do {
            try compile(["clang", "-c", shim.appendingPathComponent("RuntimeShim.c").path, "-I", shim.appendingPathComponent("include").path, "-o", directory.appendingPathComponent("shim.o").path])
            for module in ["ReminderCore", "ReminderRuntime"] {
                let shimObject = module == "ReminderRuntime" ? [directory.appendingPathComponent("shim.o").path] : []
                try compile(["swiftc", "-swift-version", "6", "-emit-library", "-emit-module", "-module-name", module,
                             "-emit-module-path", directory.appendingPathComponent(module + ".swiftmodule").path] + imports + files(module) + shimObject +
                            ["-o", directory.appendingPathComponent("lib" + module + ".dylib").path])
            }
            try compile(["swiftc", "-swift-version", "6"] + imports + files("ReminderCLI") + [source.path,
                         "-L", directory.path, "-lReminderCore", "-lReminderRuntime", "-Xlinker", "-rpath", "-Xlinker", directory.path, "-o", executable.path])
        } catch { try? manager.removeItem(at: directory); throw error }
    }
    private func compile(_ arguments: [String]) throws {
        let log = directory.appendingPathComponent("compiler.log")
        _ = FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log); defer { try? handle.close() }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun"); process.arguments = arguments
        process.standardOutput = handle; process.standardError = handle
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: "CLIFrontendFixtureCompiler", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(decoding: try Data(contentsOf: log), as: UTF8.self)]) }
    }
}

private let frontendFixtureSource = #"""
import Foundation
import Darwin
import ReminderRuntime
let args = CommandLine.arguments
if args.count > 1 && args[1] == "worker" {
    let channel = try WorkerChannel(buildID: "fixture-signal")
    _ = try channel.readRequest()
    if args[3] == "after" { try channel.mutationStarted() }
    try String(getpid()).write(toFile: args[2], atomically: true, encoding: .utf8)
    while true { Thread.sleep(forTimeInterval: 1) }
} else {
    let client = RuntimeClient(executable: URL(fileURLWithPath: args[0]), arguments: ["worker", args[1], args[2]])
    exit(frontend(["done", "fixture-id", "--version", "fixture-version", "--json"], client: client, buildID: "fixture-signal"))
}
"""#
