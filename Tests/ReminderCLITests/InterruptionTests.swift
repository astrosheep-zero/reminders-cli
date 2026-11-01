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

struct FrontendFixture {
    let directory: URL
    let executable: URL
    init(mcp: Bool = false) throws {
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
            if mcp {
                // Link the same built modules as the executable, with only the worker/backend injected.
                let products = root.appendingPathComponent(".build/debug")
                let modules = ["ReminderMCP", "ReminderFacade", "ReminderCore", "ReminderRuntime", "RuntimeShim", "MCP", "SystemPackage", "CSystem", "Logging", "EventSource"]
                let objects = try modules.flatMap { name -> [String] in
                    let aggregate = products.appendingPathComponent(name + ".o")
                    if manager.fileExists(atPath: aggregate.path) { return [aggregate.path] }
                    let build = products.appendingPathComponent(name + ".build")
                    return try manager.contentsOfDirectory(atPath: build.path).filter { $0.hasSuffix(".o") }.map { build.appendingPathComponent($0).path }
                }
                try compile(["swiftc", "-swift-version", "6", "-target", "arm64-apple-macosx26.0", "-D", "MCP_FIXTURE", "-I", products.path,
                    "-I", root.appendingPathComponent(".build/checkouts/swift-system/Sources/CSystem/include").path] + imports + [source.path] + objects + ["-o", executable.path])
                return
            }
            try compile(["clang", "-c", shim.appendingPathComponent("RuntimeShim.c").path, "-I", shim.appendingPathComponent("include").path, "-o", directory.appendingPathComponent("shim.o").path])
            for module in ["ReminderCore", "ReminderRuntime", "ReminderFacade"] {
                let shimObject = module == "ReminderRuntime" ? [directory.appendingPathComponent("shim.o").path] : []
                try compile(["swiftc", "-swift-version", "6", "-emit-library", "-emit-module", "-module-name", module,
                             "-emit-module-path", directory.appendingPathComponent(module + ".swiftmodule").path] + imports + files(module) + shimObject + (module == "ReminderFacade" ? ["-L", directory.path, "-lReminderCore", "-lReminderRuntime"] : []) +
                            ["-o", directory.appendingPathComponent("lib" + module + ".dylib").path])
            }
            try compile(["swiftc", "-swift-version", "6"] + imports + files("ReminderCLI") + [source.path,
                         "-L", directory.path, "-lReminderCore", "-lReminderRuntime", "-lReminderFacade", "-Xlinker", "-rpath", "-Xlinker", directory.path, "-o", executable.path])
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
import ReminderCore
import ReminderFacade
#if MCP_FIXTURE
import ReminderMCP
#endif
final class ProtocolBackend: ReminderBackend {
    func checkSupport(for command: Command) throws {}
    func reminder(id: String) throws -> Reminder? {
        Reminder(id: id, fields: ReminderFields(title: "Protocol fixture", listID: "L", due: .date(CalendarDate(2030, 2, 3)), position: .after("neighbor")))
    }
    func catalog(_ scopes: Set<CatalogScope>, listID: String? = nil) throws -> Catalog { Catalog(lists: [ReminderList(id: "L", fields: ListFields(name: "Inbox"))]) }
    func createReminder(_ draft: ReminderDraft) throws -> MutationResult { MutationResult(affectedIDs: ["created"], reminders: [Reminder(id: "created", fields: draft.fields)]) }
}
let args = CommandLine.arguments
if args.count > 1 && args[1] == "worker" {
    #if MCP_FIXTURE
    let descriptor = open(args[2] + ".launches", O_WRONLY | O_CREAT | O_APPEND, 0o600)
    guard descriptor >= 0 else { fatalError("Cannot record worker launch") }
    let launches = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    try launches.write(contentsOf: Data("\(getpid())\n".utf8))
    try launches.close()
    #endif
    let channel = try WorkerChannel(buildID: "fixture-signal")
    let data = try channel.readRequest()
    if ["success", "malformed", "wrong", "failure"].contains(args[3]) {
        let request = try JSONDecoder().decode(WorkerRequest.self, from: data)
        let engine = WorkerComposition(backend: { ProtocolBackend() }, diagnose: { _ in
            Diagnostics(authorization: "fixture", sandbox: "fixture", buildID: "fixture-signal", capabilities: [], notes: [])
        }, authorize: { fatalError("No setup through MCP") })
        var response = engine.execute(request, beforeMutation: { try channel.mutationStarted() })
        if args[3] == "wrong" { response = .operation(ExecutionResult(status: .ok, result: .catalog(Catalog()))) }
        if args[3] == "failure" { response = .operation(ExecutionResult(status: .failed, error: Failure(.backend, "Contradictory post-marker failure"))) }
        try String(getpid()).write(toFile: args[2], atomically: true, encoding: .utf8)
        try channel.finish(result: args[3] == "malformed" ? Data("bad payload".utf8) : JSONEncoder().encode(response))
    } else {
        if args[3] == "after" { try channel.mutationStarted() }
        try String(getpid()).write(toFile: args[2], atomically: true, encoding: .utf8)
        while true { _ = sleep(1) }
    }
} else {
    #if MCP_FIXTURE
    let client = RuntimeClient(executable: URL(fileURLWithPath: args[0]), arguments: ["worker", args[1], "after"])
    do { try await MCPFrontend(facade: RemindersFacade(client: client, buildID: "fixture-signal")).run(); exit(0) }
    catch { exit(6) }
    #else
    let client = RuntimeClient(executable: URL(fileURLWithPath: args[0]), arguments: ["worker", args[1], args[2]])
    exit(frontend(["done", "fixture-id", "--version", "fixture-version", "--json"], client: client, buildID: "fixture-signal"))
    #endif
}
"""#
