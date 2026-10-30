import Foundation
import RuntimeShim

/// A worker owns one channel and must exit after finish (or any thrown error).
/// Use stdout exclusively for this protocol; send native diagnostics to stderr.
public final class WorkerChannel: @unchecked Sendable {
    private let lock = NSLock()
    private let input: Int32
    private let output: Int32
    private enum State { case announced, requested, mutating, finished, broken }
    private var state = State.announced

    /// Announces the build before reading any command. Descriptors are borrowed, not closed.
    public init(buildID: String, input: Int32 = 0, output: Int32 = 1) throws {
        guard validBuildID(buildID) else { throw RuntimeIssue.invalidConfiguration }
        self.input = input
        self.output = output
        try write(Frame(type: "hello", buildID: buildID))
    }

    /// Reads exactly one bounded request line and requires EOF after it.
    /// RuntimeClient closes stdin after sending the line; a second request is forbidden.
    public func readRequest() throws -> Data {
        try lock.withLock {
            guard state == .announced else { throw RuntimeIssue.unexpectedFrame }
            do {
                var parser = Lines()
                var request: Data?
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    var error: Int32 = 0
                    let count = rr_read(input, &buffer, buffer.count, &error)
                    if count == -1 { continue }
                    if count < 0 { throw RuntimeIssue.io(code: error) }
                    if count == 0 {
                        guard !parser.hasPartial, let request else { throw RuntimeIssue.truncatedOutput }
                        state = .requested
                        return request
                    }
                    try parser.append(Data(buffer.prefix(Int(count)))) { line in
                        guard request == nil else { throw RuntimeIssue.unexpectedFrame }
                        let frame = try Frame.decode(line)
                        guard frame.type == "request" else { throw RuntimeIssue.unexpectedFrame }
                        request = try frame.bytes()
                    }
                }
            } catch {
                state = .broken
                throw error
            }
        }
    }

    /// Call synchronously immediately before the first actual save. On error, DO NOT save.
    /// Idempotent for subsequent Core callbacks in this same one-shot operation.
    public func mutationStarted() throws {
        try lock.withLock {
            guard state == .requested || state == .mutating else { throw RuntimeIssue.unexpectedFrame }
            if state == .mutating { return }
            do {
                try write(Frame(type: "mutationStarted"))
                state = .mutating
            } catch { state = .broken; throw error }
        }
    }

    /// Opaque result may encode Core success, failure, or partial/unknown evidence.
    /// A throwing oversized-result/write failure after mutation must not be reported as no-write.
    public func finish(result: Data) throws {
        try lock.withLock {
            guard state == .requested || state == .mutating else { throw RuntimeIssue.unexpectedFrame }
            do {
                guard result.count <= RuntimeLimits.payloadBytes else { throw RuntimeIssue.oversizedPayload }
                try write(Frame(type: "result", payload: result.base64EncodedString()))
                state = .finished
            } catch { state = .broken; throw error }
        }
    }

    private func write(_ frame: Frame) throws {
        let data = try frame.line()
        let error = data.withUnsafeBytes { rr_write_all(output, $0.baseAddress!, data.count) }
        if error != 0 { throw RuntimeIssue.io(code: error) }
    }
}
