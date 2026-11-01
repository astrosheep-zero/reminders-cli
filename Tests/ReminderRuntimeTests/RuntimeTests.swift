import Foundation
import Testing
import Darwin
import ReminderRuntime

@Suite(.serialized)
struct ReminderRuntimeTests {
    private let fixture: Fixture
    init() throws { fixture = try Fixture() }

    private func run(_ mode: String, data: Data = Data("opaque\u{0}data".utf8),
                     deadline: TimeInterval = 5, artifact: String = "") -> RuntimeReply {
        let reply = RuntimeClient(executable: fixture.worker, arguments: [mode, artifact])
            .execute(request: data, buildID: "fixture-v1", deadline: deadline)
        if let pid = reply.processID {
            var status: Int32 = 0
            #expect(waitpid(pid, &status, WNOHANG) == -1, "Runtime must reap its own child")
            #expect(errno == ECHILD)
            #expect(kill(pid, 0) == -1, "Fixture may not remain running")
        }
        return reply
    }

    @Test func roundTripAndMutationCallback() {
        let bytes = Data((0...255).map(UInt8.init))
        for mode in ["echo", "mutation", "workerAPI"] {
            let reply = run(mode, data: bytes)
            #expect(reply.outcome == .result(bytes))
            #expect(reply.issue == nil)
            #expect(reply.exitStatus == 0)
            #expect(reply.mutationStarted == (mode != "echo"))
        }
    }

    @Test func handshakeRefusalNeverDispatches() {
        for mode in ["mismatch", "badHello", "noHello"] {
            let artifact = fixture.directory.appendingPathComponent(mode).path
            let reply = run(mode, artifact: artifact)
            guard case .failed = reply.outcome else { Issue.record("\(reply)"); return }
            #expect(!FileManager.default.fileExists(atPath: artifact))
            #expect(reply.issue == (mode == "mismatch" ? .buildMismatch :
                                   (mode == "badHello" ? .invalidFrame : .unexpectedFrame)))
        }
    }

    @Test func crashClassification() {
        #expect(run("crashBefore").outcome == .failed(.workerExited))
        #expect(run("crashAfter").outcome == .outcomeUnknown(.workerExited))
        #expect(run("partialAfter").outcome == .outcomeUnknown(.truncatedOutput))
        #expect(run("badAfter").outcome == .outcomeUnknown(.invalidFrame))
        #expect(run("duplicateMutation").outcome == .outcomeUnknown(.unexpectedFrame))
        #expect(run("workerOversizeAfter").outcome == .outcomeUnknown(.workerExited))
    }

    @Test func malformedAndOutOfOrderFrames() {
        #expect(run("badPayload").outcome == .outcomeUnknown(.invalidFrame))
        #expect(run("extraField").outcome == .outcomeUnknown(.invalidFrame))
        #expect(run("duplicateKeys").outcome == .outcomeUnknown(.invalidFrame))
        #expect(run("duplicateHello").outcome == .outcomeUnknown(.unexpectedFrame))
        #expect(run("oversizedHello").outcome == .failed(.oversizedPayload))
        #expect(run("oversizedResult").outcome == .outcomeUnknown(.oversizedPayload))
    }

    @Test func stderrSaturationAndConcurrentPipes() {
        // All-slash base64 also verifies the JSON encoder does not double the wire size.
        let data = Data(repeating: 255, count: RuntimeLimits.payloadBytes)
        let reply = run("duplex", data: data, deadline: 20)
        #expect(reply.outcome == .result(data))
        #expect(reply.diagnostics.count == RuntimeLimits.diagnosticBytes)
        #expect(reply.diagnosticsTruncated)
        #expect(reply.issue == nil)
    }

    @Test func deadlineAndBackpressuredInput() {
        #expect(run("startupHang", deadline: 0.2).outcome == .failed(.deadline))
        #expect(run("hangBefore", deadline: 2).outcome == .failed(.deadline))
        #expect(run("hangAfter", deadline: 2).outcome == .outcomeUnknown(.deadline))
        let data = Data(repeating: 7, count: RuntimeLimits.payloadBytes)
        let reply = run("noRead", data: data, deadline: 2)
        #expect(reply.outcome == .failed(.deadline))
        #expect(reply.diagnostics.count == RuntimeLimits.diagnosticBytes)
    }

    @Test func cancellationTerminatesAndReaps() throws {
        let artifact = fixture.directory.appendingPathComponent("cancel-ready")
        let token = RuntimeCancellation()
        let source = Task.detached {
            let start = ProcessInfo.processInfo.systemUptime
            while !FileManager.default.fileExists(atPath: artifact.path) &&
                    ProcessInfo.processInfo.systemUptime - start < 3 { try await Task.sleep(for: .milliseconds(10)) }
            token.cancel()
        }
        defer { source.cancel() }
        let reply = RuntimeClient(executable: fixture.worker, arguments: ["hangAfter", artifact.path])
            .execute(request: Data(), buildID: "fixture-v1", deadline: 5, cancellation: token)
        #expect(reply.outcome == .outcomeUnknown(.cancelled))
        var status: Int32 = 0
        #expect(waitpid(try #require(reply.processID), &status, WNOHANG) == -1)
        #expect(errno == ECHILD)
    }

    @Test func authoritativeResultSurvivesAbnormalExitAndDeadline() {
        let data = Data("accepted".utf8)
        for mode in ["nonzeroAfter", "hangResult"] {
            let reply = run(mode, data: data, deadline: 2)
            #expect(reply.outcome == .result(data), "mode: \(mode)")
            #expect(reply.issue != nil)
        }
    }

    @Test func exitedWorkerDoesNotWaitForDescendantPipes() throws {
        let artifact = fixture.directory.appendingPathComponent("descendant-pid")
        let bytes = Data("finished".utf8)
        let reply = run("inheritedPipes", data: bytes, deadline: 5, artifact: artifact.path)
        let pid = try #require(Int32(String(contentsOf: artifact, encoding: .utf8)))
        #expect(reply.outcome == .result(bytes))
        #expect(reply.issue == nil)
        #expect(reply.exitStatus == 0)
        // Give the OS time to reap the orphaned descendant after the group kill.
        let end = ProcessInfo.processInfo.systemUptime + 2
        while kill(pid, 0) == 0 && ProcessInfo.processInfo.systemUptime < end { usleep(10_000) }
        let gone = kill(pid, 0) == -1 && errno == ESRCH
        if !gone { kill(pid, SIGKILL) } // Avoid leaving the fixture behind on failure.
        #expect(gone)
    }

    @Test func normalExitsDoNotEachWaitForTerminationGrace() {
        // Aggregate the delay across calls so this allows ample process launch
        // overhead while catching the former unconditional 100 ms per call.
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<25 {
            let reply = run("echo")
            #expect(reply.issue == nil)
            #expect(reply.outcome == .result(Data("opaque\u{0}data".utf8)))
        }
        #expect(ProcessInfo.processInfo.systemUptime - start < 2.25)
    }

    @Test func trailingCorruptionInvalidatesFinalResult() {
        for mode in ["trailingAfter", "mutatingTrailing", "duplicateResult", "mutatingDuplicateResult"] {
            let reply = run(mode)
            let expected: RuntimeIssue = mode.contains("Trailing") || mode == "trailingAfter" ? .invalidFrame : .unexpectedFrame
            #expect(reply.outcome == .outcomeUnknown(expected), "mode: \(mode)")
            #expect(reply.mutationStarted == mode.hasPrefix("mutating"))
        }
        #expect(run("partialTrailing").outcome == .outcomeUnknown(.truncatedOutput))
        let artifact = fixture.directory.appendingPathComponent("mutation-hidden-by-corruption").path
        let reply = run("corruptThenMarker", artifact: artifact)
        #expect(FileManager.default.fileExists(atPath: artifact))
        #expect(reply.outcome == .outcomeUnknown(.invalidFrame))
    }

    @Test func inputBoundsAndConfiguration() {
        let client = RuntimeClient(executable: fixture.worker, arguments: ["echo"])
        let oversized = client.execute(request: Data(repeating: 0, count: RuntimeLimits.payloadBytes + 1), buildID: "fixture-v1")
        #expect(oversized.outcome == .failed(.oversizedPayload))
        #expect(oversized.processID == nil)
        for buildID in ["", String(repeating: "x", count: 129), "bad\u{0}id"] {
            #expect(client.execute(request: Data(), buildID: buildID).outcome == .failed(.invalidConfiguration))
        }
        #expect(client.execute(request: Data(), buildID: "ok", deadline: .nan).outcome == .failed(.invalidConfiguration))
        let cancelled = RuntimeCancellation()
        cancelled.cancel()
        #expect(client.execute(request: Data(), buildID: "ok", cancellation: cancelled).processID == nil)
        let missing = RuntimeClient(executable: URL(fileURLWithPath: "/nonexistent-runtime-fixture"))
            .execute(request: Data(), buildID: "ok")
        guard case .failed(.spawnRefused) = missing.outcome else { Issue.record("\(missing)"); return }
        #expect(missing.processID == nil)
    }

    @Test func workerRejectsInvalidRequests() throws {
        let valid = "{\"type\":\"request\",\"payload\":\"\"}\n"
        let cases: [(String, RuntimeIssue)] = [
            ("{broken}\n", .invalidFrame),
            (String(valid.dropLast()), .truncatedOutput),
            (valid + valid, .unexpectedFrame),
            ("{\"type\":\"hello\",\"buildID\":\"wrong-direction\"}\n", .unexpectedFrame),
            ("{\"type\":\"request\",\"payload\":\"!!!!\"}\n", .invalidFrame)
        ]
        for (wire, expected) in cases {
            var input: [Int32] = [-1, -1]
            var output: [Int32] = [-1, -1]
            try #require(pipe(&input) == 0)
            try #require(pipe(&output) == 0)
            defer { close(input[0]); close(output[0]); close(output[1]) }
            let bytes = Data(wire.utf8)
            let sent = bytes.withUnsafeBytes { Darwin.write(input[1], $0.baseAddress!, bytes.count) }
            close(input[1])
            #expect(sent == bytes.count)
            let channel = try WorkerChannel(buildID: "fixture-v1", input: input[0], output: output[1])
            #expect(throws: RuntimeIssue.unexpectedFrame) { try channel.mutationStarted() }
            #expect(throws: expected) { try channel.readRequest() }
            #expect(throws: RuntimeIssue.unexpectedFrame) { try channel.finish(result: Data()) }
        }
    }

    @Test func unrelatedDescriptorsAreClosed() throws {
        let path = fixture.directory.appendingPathComponent("private-file").path
        let original = open(path, O_CREAT | O_RDWR, 0o600)
        #expect(original >= 0)
        // A high inheritable descriptor avoids incidental dynamic-loader fd reuse in the worker.
        let descriptor = fcntl(original, F_DUPFD, 200)
        defer { close(original); close(descriptor) }
        #expect(descriptor >= 200)
        #expect(run("descriptor", data: Data(String(descriptor).utf8)).outcome == .result(Data("closed".utf8)))
    }

    @Test func environmentFiltering() {
        setenv("DYLD_REMINDER_RUNTIME_TEST", "must-not-inherit", 1)
        defer { unsetenv("DYLD_REMINDER_RUNTIME_TEST") }
        #expect(run("environment").outcome == .result(Data()))
        _ = SandboxState.current // Explicit observation, intentionally not a TCC assertion.
    }
}

private final class Fixture {
    let directory: URL
    let worker: URL

    init() throws {
        let manager = FileManager.default
        directory = manager.temporaryDirectory.appendingPathComponent("reminder-runtime-\(UUID().uuidString)")
        worker = directory.appendingPathComponent("worker")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let shim = root.appendingPathComponent("Sources/RuntimeShim")
        let moduleMap = directory.appendingPathComponent("module.modulemap")
        try "module RuntimeShim { header \"\(shim.path)/include/RuntimeShim.h\" export * }".write(to: moduleMap, atomically: true, encoding: .utf8)
        let source = directory.appendingPathComponent("main.swift")
        try workerFixtureSource.write(to: source, atomically: true, encoding: .utf8)
        let object = directory.appendingPathComponent("shim.o").path
        let library = directory.appendingPathComponent("libReminderRuntime.dylib").path
        do {
            try compile(["clang", "-c", shim.appendingPathComponent("RuntimeShim.c").path,
                         "-I", shim.appendingPathComponent("include").path, "-o", object])
            let sources = try manager.contentsOfDirectory(atPath: root.appendingPathComponent("Sources/ReminderRuntime").path)
                .filter { $0.hasSuffix(".swift") }
                .map { root.appendingPathComponent("Sources/ReminderRuntime/\($0)").path }
            let imports = ["-I", directory.path, "-Xcc", "-fmodule-map-file=\(moduleMap.path)"]
            try compile(["swiftc", "-swift-version", "6", "-emit-library", "-emit-module", "-module-name", "ReminderRuntime",
                         "-emit-module-path", directory.appendingPathComponent("ReminderRuntime.swiftmodule").path] + imports +
                        sources + [object, "-o", library])
            try compile(["swiftc", "-swift-version", "6"] + imports + [source.path, "-L", directory.path,
                        "-lReminderRuntime", "-Xlinker", "-rpath", "-Xlinker", directory.path, "-o", worker.path])
        } catch {
            try? manager.removeItem(at: directory)
            throw error
        }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    private func compile(_ arguments: [String]) throws {
        let log = directory.appendingPathComponent("compiler.log")
        _ = FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "FixtureCompiler", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: String(decoding: try Data(contentsOf: log), as: UTF8.self)])
        }
    }
}
