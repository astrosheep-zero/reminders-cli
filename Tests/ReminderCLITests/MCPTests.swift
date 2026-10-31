import Foundation
import Darwin
import Testing
import MCP
import ReminderRuntime
import ReminderFacade
import ReminderMCP

struct MCPTests {
    @Test func officialClientServerDiscoversAndCallsRealFacadeThroughRuntime() async throws {
        let fixture = try FrontendFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        for mode in ["success", "malformed", "wrong", "failure"] {
            let artifact = fixture.directory.appendingPathComponent(mode)
            let facade = RemindersFacade(client: RuntimeClient(executable: fixture.executable, arguments: ["worker", artifact.path, mode]), buildID: "fixture-signal")
            let service = MCPFrontend(facade: facade), client = Client(name: "offline-test", version: "1")
            let pair = await InMemoryTransport.createConnectedPair()
            try await service.start(transport: pair.server)
            let initialized = try await client.connect(transport: pair.client)
            #expect(initialized.protocolVersion == "2025-11-25")
            #expect(initialized.serverInfo.version == "0.1.1"); #expect(initialized.capabilities.tools != nil)
            let (tools, next) = try await client.listTools()
            #expect(next == nil); #expect(Set(tools.map(\.name)) == Set(FacadeOperations.definitions.map(\.toolName)))
            #expect(!tools.contains { $0.name == "setup" }); #expect(tools.first { $0.name == "show" }?.annotations.readOnlyHint == true)
            #expect(tools.first { $0.name == "lists_delete" }?.annotations.destructiveHint == true)
            let blocked: RequestContext<CallTool.Result> = try await client.send(CallTool.request(.init(name: "setup", arguments: [:])))
            let blockedResult = try await blocked.value
            #expect(blockedResult.isError == true)
            #expect(!FileManager.default.fileExists(atPath: artifact.path))
            let request: RequestContext<CallTool.Result> = try await client.send(CallTool.request(.init(name: "add", arguments: ["title": "T", "list": "L"])))
            let result = try await request.value
            let envelope = try JSONDecoder().decode(OutputEnvelope.self, from: JSONEncoder().encode(result.structuredContent))
            #expect(envelope.status == (mode == "success" ? .ok : .unknown))
            #expect(result.isError == (mode != "success"))
            if mode != "success" { #expect(envelope.error?.code == .outcomeUnknown) }
            guard case .text(let text, _, _) = result.content.first else { throw invalid("Expected JSON text fallback") }
            #expect(try JSONDecoder().decode(OutputEnvelope.self, from: Data(text.utf8)).status == envelope.status)
            try await client.ping()
            await service.stop(); await client.disconnect()
        }
    }
    @Test func officialCancellationNotificationReachesRuntimeAndReapsWorker() async throws {
        let fixture = try FrontendFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let artifact = fixture.directory.appendingPathComponent("sdk-cancel")
        let facade = RemindersFacade(client: RuntimeClient(executable: fixture.executable, arguments: ["worker", artifact.path, "after"]), buildID: "fixture-signal")
        let service = MCPFrontend(facade: facade), client = Client(name: "offline-test", version: "1")
        let pair = await InMemoryTransport.createConnectedPair()
        try await service.start(transport: pair.server); try await client.connect(transport: pair.client)
        let context: RequestContext<CallTool.Result> = try await client.send(CallTool.request(.init(name: "add", arguments: ["title": "T", "list": "L"])))
        let pid = try await awaitFixturePID(artifact)
        // ping while a worker is hung proves blocking Runtime work is not on the SDK receive actor.
        try await client.ping()
        try await client.cancelRequest(context.requestID, reason: "offline cancellation test")
        do { _ = try await context.value; Issue.record("Official client must cancel its waiter") } catch is CancellationError {}
        let end = ProcessInfo.processInfo.systemUptime + 5
        while kill(pid, 0) == 0, ProcessInfo.processInfo.systemUptime < end { try await Task.sleep(for: .milliseconds(10)) }
        #expect(kill(pid, 0) == -1); #expect(errno == ESRCH)
        try await client.ping()
        await service.stop(); await client.disconnect()
    }
    @Test func brokenStdoutThenEOFReapsActiveWorkerAndNeverSpawnsQueuedCall() async throws {
        let fixture = try FrontendFixture(mcp: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let artifact = fixture.directory.appendingPathComponent("broken-stdout.pid")
        try await exerciseBrokenStdout(executable: fixture.executable, arguments: [artifact.path], workerArtifact: artifact)
    }
    @Test func actualExecutableSurvivesBrokenStdoutBeforeEOFWithoutNativeAccess() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try await exerciseBrokenStdout(executable: root.appendingPathComponent(".build/debug/reminder"), arguments: ["mcp"])
    }
    @Test func actualExecutableStdioInitializeListInvalidCallAndEOFWithoutNativeAccess() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = root.appendingPathComponent(".build/debug/reminder"); process.arguments = ["mcp"]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        try input.fileHandleForReading.close(); try output.fileHandleForWriting.close()
        let transport = StdioTransport(input: .init(rawValue: output.fileHandleForReading.fileDescriptor), output: .init(rawValue: input.fileHandleForWriting.fileDescriptor))
        let client = Client(name: "offline-stdio-test", version: "1")
        let initialized = try await client.connect(transport: transport)
        #expect(initialized.protocolVersion == "2025-11-25")
        let (tools, _) = try await client.listTools()
        #expect(tools.count == FacadeOperations.definitions.count)
        let result: RequestContext<CallTool.Result> = try await client.send(CallTool.request(.init(name: "show", arguments: ["id": "R", "unexpected": true])))
        #expect(try await result.value.isError == true)
        await client.disconnect()
        try input.fileHandleForWriting.close() // Actual EOF, not a product test hook.
        let end = ProcessInfo.processInfo.systemUptime + 5
        while process.isRunning, ProcessInfo.processInfo.systemUptime < end { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!process.isRunning)
        if !process.isRunning { process.waitUntilExit(); #expect(process.terminationStatus == 0) }
        try output.fileHandleForReading.close()
    }
}

/// Only the worker is injected. Both subprocesses run production MCPFrontend.run,
/// the official SDK/stdio transport, and the real serialized facade/Runtime path.
private func exerciseBrokenStdout(executable: URL, arguments: [String], workerArtifact: URL? = nil) async throws {
    let process = Process(), input = Pipe(), output = Pipe()
    // Do not inherit an ignored SIGPIPE from the test runner and accidentally mask the bug.
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "trap - PIPE; exec \"$@\"", "mcp-sigpipe-regression", executable.path] + arguments
    process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
    var workerPID: Int32?
    defer {
        if let workerPID, kill(workerPID, 0) == 0 { _ = kill(workerPID, SIGKILL) }
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
        try? input.fileHandleForReading.close(); try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
    }
    try process.run()
    try input.fileHandleForReading.close(); try output.fileHandleForWriting.close()
    let transport = StdioTransport(input: .init(rawValue: output.fileHandleForReading.fileDescriptor), output: .init(rawValue: input.fileHandleForWriting.fileDescriptor))
    let client = Client(name: "offline-sigpipe-test", version: "1")
    do {
        _ = try await client.connect(transport: transport)
        if let workerArtifact {
            let active: RequestContext<CallTool.Result> = try await client.send(CallTool.request(.init(name: "add", arguments: ["title": "T", "list": "L"])))
            workerPID = try await awaitFixturePID(workerArtifact)
            let queued: RequestContext<CallTool.Result> = try await client.send(CallTool.request(.init(name: "show", arguments: ["id": "queued"])))
            // Responses to these real SDK requests prove the receive loop stays runnable
            // while the first worker hangs and the second data call waits for its queue.
            try await client.ping()
            _ = try await client.listTools()
            try await Task.sleep(for: .milliseconds(100))
            withExtendedLifetime((active, queued)) {}
        }
        // Disconnect only the local SDK reader/waiters; keep the child's stdin OPEN.
        // No cancellation notification or EOF is sent to the server here.
        await client.disconnect()
        try output.fileHandleForReading.close()
        let request = ListTools.request(id: .string("broken-stdout"), .init())
        try input.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(request) + Data([10]))
        // The tools/list response now writes to a pipe with no readers (EPIPE).
        // EOF comes later, so an exit here cannot masquerade as successful shutdown.
        try await Task.sleep(for: .milliseconds(250))
        let survived = process.isRunning
        let state = survived ? "running" : "\(process.terminationReason), status \(process.terminationStatus)"
        try #require(survived, "MCP must survive EPIPE before EOF, not terminate on SIGPIPE: \(state)")
        if let workerPID { #expect(kill(workerPID, 0) == 0, "The active worker must still be waiting until shutdown") }
        try input.fileHandleForWriting.close()
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(!process.isRunning, "EOF must cancel and drain the queue without waiting for the worker deadline")
        process.waitUntilExit()
        #expect(process.terminationReason == .exit); #expect(process.terminationStatus == 0)
        if let workerPID, let workerArtifact {
            #expect(kill(workerPID, 0) == -1); #expect(errno == ESRCH, "Active disclaimed worker must be reaped before frontend exit")
            let launches = try String(contentsOf: URL(fileURLWithPath: workerArtifact.path + ".launches"), encoding: .utf8)
            #expect(launches.split(separator: "\n").map(String.init) == [String(workerPID)], "The queued call must never launch a second worker")
        }
    } catch {
        await client.disconnect()
        throw error
    }
}
