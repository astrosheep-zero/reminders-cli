import Foundation
import RuntimeShim

/// One process per call. No retries, native permission queries, or Core dependency.
public struct RuntimeClient: Sendable {
    public let executable: URL?
    public let arguments: [String]

    /// Nil executable means the canonical path of the running executable.
    /// Injection changes only the executable/arguments, never the disclaim requirement.
    public init(executable: URL? = nil, arguments: [String] = ["--worker"]) {
        self.executable = executable
        self.arguments = arguments
    }

    public func execute(
        request: Data, buildID: String,
        deadline: TimeInterval = RuntimeLimits.defaultDeadline,
        cancellation: RuntimeCancellation? = nil
    ) -> RuntimeReply {
        let start = ProcessInfo.processInfo.systemUptime
        func refusal(_ issue: RuntimeIssue) -> RuntimeReply {
            RuntimeReply(outcome: .failed(issue), diagnostics: Data(), diagnosticsTruncated: false,
                         mutationStarted: false, issue: issue, exitStatus: nil, processID: nil)
        }
        guard validBuildID(buildID), deadline.isFinite, deadline > 0,
              arguments.allSatisfy({ !$0.utf8.contains(0) }) else {
            return refusal(.invalidConfiguration)
        }
        guard request.count <= RuntimeLimits.payloadBytes else { return refusal(.oversizedPayload) }
        if cancellation?.isCancelled == true { return refusal(.cancelled) }
        let path: String
        if let executable {
            guard executable.isFileURL else { return refusal(.invalidConfiguration) }
            path = executable.resolvingSymlinksInPath().path
        } else {
            guard let resolved = rr_executable_path() else { return refusal(.invalidConfiguration) }
            path = String(cString: resolved)
            rr_free(resolved)
        }
        guard !path.utf8.contains(0), path.hasPrefix("/") else { return refusal(.invalidConfiguration) }
        let environment = ProcessInfo.processInfo.environment
            .filter { !$0.key.hasPrefix("DYLD_") }
            .map { "\($0.key)=\($0.value)" }
        var child = rr_child()
        var disclaim: Int32 = 0
        let code = withCStringArray([path] + arguments) { argv in
            withCStringArray(environment) { env in
                rr_spawn(path, argv, env, &child, &disclaim)
            }
        }
        guard code == 0 else { return refusal(.spawnRefused(code: code, disclaim: disclaim != 0)) }
        var session = Session(child: child, buildID: buildID, request: request)
        return session.run(until: start + deadline, cancellation: cancellation)
    }
}

func validBuildID(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 128 && !value.utf8.contains(0)
}

private func withCStringArray<T>(_ values: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> T) -> T {
    let storage = values.map { value -> UnsafeMutablePointer<CChar> in
        let bytes = Array(value.utf8CString)
        let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
        pointer.initialize(from: bytes, count: bytes.count)
        return pointer
    }
    defer { storage.forEach { $0.deallocate() } }
    return (storage.map(Optional.some) + [nil]).withUnsafeBufferPointer { body($0.baseAddress!) }
}

private struct Session {
    let child: rr_child
    let buildID: String
    let request: Data
    var input: Int32
    var output: Int32
    var diagnostic: Int32
    var lines = Lines()
    var hello = false
    var dispatched = false
    var mutation = false
    var result: Data?
    var issue: RuntimeIssue?
    var diagnostics = Data()
    var diagnosticsTruncated = false
    var outbound: Data?
    var written = 0
    var status: Int32?
    var parsing = true

    init(child: rr_child, buildID: String, request: Data) {
        self.child = child
        self.buildID = buildID
        self.request = request
        input = child.input_fd
        output = child.output_fd
        diagnostic = child.error_fd
    }

    mutating func run(until end: TimeInterval, cancellation: RuntimeCancellation?) -> RuntimeReply {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while issue == nil {
            if cancellation?.isCancelled == true { issue = .cancelled; break }
            let remaining = end - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 { issue = .deadline; break }
            var observedStatus: Int32 = 0
            let exited = rr_reap(child.pid, &observedStatus)
            if exited < 0 { issue = .io(code: 10); break }
            if exited == 1 { status = observedStatus }
            if status != nil && output < 0 && diagnostic < 0 { break }
            var ready: Int32 = 0
            let polling = rr_poll(outbound == nil ? -1 : input, output, diagnostic,
                                  Int32(min(20, max(1, remaining * 1000))), &ready)
            if polling != 0 { issue = .io(code: polling); break }
            // Read before writing: no request is released until hello has been validated.
            if ready & 2 != 0 {
                var error: Int32 = 0
                let count = rr_read(output, &buffer, buffer.count, &error)
                if count > 0 {
                    consumeOutput(Data(buffer.prefix(Int(count))))
                } else if count == 0 {
                    rr_close(output); output = -1
                    if lines.hasPartial {
                        parsing = false
                        result = nil
                        issue = .truncatedOutput
                    }
                } else if count == -2 { issue = .io(code: error) }
            }
            if ready & 4 != 0 {
                var error: Int32 = 0
                let count = rr_read(diagnostic, &buffer, buffer.count, &error)
                if count > 0 {
                    consumeDiagnostics(Data(buffer.prefix(Int(count))))
                } else if count == 0 { rr_close(diagnostic); diagnostic = -1 }
                else if count == -2 { issue = .io(code: error) }
            }
            if issue == nil, ready & 1 != 0, let data = outbound {
                var error: Int32 = 0
                let count = data.withUnsafeBytes { bytes in
                    rr_write(input, bytes.baseAddress!.advanced(by: written), min(65536, data.count - written), &error)
                }
                if count > 0 {
                    written += Int(count)
                    if written == data.count {
                        dispatched = true
                        outbound = nil
                        rr_close(input); input = -1
                    }
                } else if count == -2 || count == 0 { issue = .io(code: error) }
            }
        }
        // Stop first, then consume bytes already committed to the pipes. In particular,
        // cancellation must not overlook a mutation marker queued just before termination.
        rr_close(input)
        var finalStatus: Int32 = 0
        let stopped = rr_stop(child.pid, &finalStatus)
        if stopped == 0 { status = finalStatus }
        else if issue == nil { issue = .io(code: stopped) }
        for fd in [output, diagnostic] where fd >= 0 {
            // Nonblocking and bounded even if a hostile descendant escaped the process group.
            for _ in 0..<512 {
                var error: Int32 = 0
                let count = rr_read(fd, &buffer, buffer.count, &error)
                if count <= 0 { break }
                let bytes = Data(buffer.prefix(Int(count)))
                if fd == output && parsing { consumeOutput(bytes) }
                if fd == diagnostic { consumeDiagnostics(bytes) }
            }
            rr_close(fd)
        }
        if lines.hasPartial {
            parsing = false
            result = nil
            if issue == nil { issue = .truncatedOutput }
        }
        if result == nil && issue == nil { issue = .workerExited }
        if result != nil && status != 0 && issue == nil { issue = .workerExited }
        let outcome: RuntimeReply.Outcome
        if let result { outcome = .result(result) }
        else if mutation || (dispatched && !parsing) { outcome = .outcomeUnknown(issue ?? .workerExited) }
        else { outcome = .failed(issue ?? .workerExited) }
        return RuntimeReply(outcome: outcome, diagnostics: diagnostics,
                            diagnosticsTruncated: diagnosticsTruncated, mutationStarted: mutation, issue: issue,
                            exitStatus: status, processID: child.pid)
    }

    mutating func consumeDiagnostics(_ bytes: Data) {
        let kept = min(bytes.count, RuntimeLimits.diagnosticBytes - diagnostics.count)
        diagnostics.append(bytes.prefix(kept))
        if kept < bytes.count { diagnosticsTruncated = true }
    }

    mutating func consumeOutput(_ bytes: Data) {
        do {
            // Separate parser storage avoids overlapping inout access to self.
            var parser = lines
            lines = Lines()
            defer { lines = parser }
            try parser.append(bytes) { try receive($0) }
        } catch {
            // Corrupt stdout can hide a queued pre-save marker. After dispatch,
            // we can no longer certify no mutation, even if no marker was parsed.
            parsing = false
            result = nil
            if issue == nil { issue = (error as? RuntimeIssue) ?? .invalidFrame }
        }
    }

    mutating func receive(_ line: Data) throws {
        let frame = try Frame.decode(line)
        if !hello {
            guard frame.type == "hello" else { throw RuntimeIssue.unexpectedFrame }
            guard let announced = frame.buildID,
                  announced.utf8.elementsEqual(buildID.utf8) else { throw RuntimeIssue.buildMismatch }
            hello = true
            outbound = try Frame(type: "request", payload: request.base64EncodedString()).line()
            return
        }
        guard dispatched, result == nil else { throw RuntimeIssue.unexpectedFrame }
        switch frame.type {
        case "mutationStarted":
            guard !mutation else { throw RuntimeIssue.unexpectedFrame }
            mutation = true
        case "result": result = try frame.bytes()
        default: throw RuntimeIssue.unexpectedFrame
        }
    }
}
