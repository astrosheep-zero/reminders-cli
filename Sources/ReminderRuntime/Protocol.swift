import Foundation
import RuntimeShim

/// Wire limits include a small envelope allowance; limits are not caller-increasable.
public enum RuntimeLimits {
    public static let payloadBytes = 16 * 1024 * 1024
    public static let diagnosticBytes = 64 * 1024
    public static let frameBytes = ((payloadBytes + 2) / 3) * 4 + 1024
    public static let defaultDeadline: TimeInterval = 30
    public static let setupDeadline: TimeInterval = 120
}

public enum RuntimeIssue: Error, Equatable, Sendable {
    case invalidConfiguration
    case oversizedPayload
    case spawnRefused(code: Int32, disclaim: Bool)
    case buildMismatch
    case invalidFrame
    case unexpectedFrame
    case truncatedOutput
    case io(code: Int32)
    case deadline
    case cancelled
    case workerExited
}

public enum SandboxState: Sendable {
    case sandboxed, notSandboxed, unknown

    /// Best effort process sandbox observation, never a Reminders permission check.
    public static var current: SandboxState {
        switch rr_sandbox_state() {
        case 0: .notSandboxed
        case 1: .sandboxed
        default: .unknown
        }
    }
}

/// Safe to share between the executing thread and a cancellation source.
public final class RuntimeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    public init() {}
    public func cancel() { lock.withLock { value = true } }
    public var isCancelled: Bool { lock.withLock { value } }
}

/// All bytes are opaque to Runtime. A final result requires a valid stdout stream.
public struct RuntimeReply: Sendable {
    public enum Outcome: Equatable, Sendable {
        case result(Data)
        case failed(RuntimeIssue)
        case outcomeUnknown(RuntimeIssue)
    }
    public let outcome: Outcome
    public let diagnostics: Data
    public let diagnosticsTruncated: Bool
    /// The worker's pre-save marker was observed; retained even with an opaque final result.
    public let mutationStarted: Bool
    /// Protocol/transport issue even when `outcome` contains an authoritative result.
    public let issue: RuntimeIssue?
    public let exitStatus: Int32?
    public let processID: Int32?
}

struct Frame: Codable {
    let type: String
    var buildID: String? = nil
    var payload: String? = nil

    static func decode(_ data: Data) throws -> Frame {
        // Reject unknown keys, non-string fields, and fields belonging to a different frame.
        guard !data.isEmpty, data.count <= RuntimeLimits.frameBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object.values.allSatisfy({ $0 is String }),
              let type = object["type"] as? String else { throw RuntimeIssue.invalidFrame }
        // Foundation dictionaries collapse duplicate JSON keys. Since all values must
        // be strings, counting colons outside strings detects that ambiguity without
        // imposing a second custom JSON grammar (including escaped-key equivalence).
        var quoted = false
        var escaped = false
        var fields = 0
        for byte in data {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 58 { fields += 1 }
        }
        guard fields == object.count else { throw RuntimeIssue.invalidFrame }
        let keys = Set(object.keys)
        let expected: Set<String>
        switch type {
        case "hello": expected = ["type", "buildID"]
        case "request", "result": expected = ["type", "payload"]
        case "mutationStarted": expected = ["type"]
        default: throw RuntimeIssue.invalidFrame
        }
        guard keys == expected else { throw RuntimeIssue.invalidFrame }
        return try JSONDecoder().decode(Frame.self, from: data)
    }

    func line() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        var data = try encoder.encode(self)
        guard data.count <= RuntimeLimits.frameBytes else { throw RuntimeIssue.oversizedPayload }
        data.append(10)
        return data
    }

    func bytes() throws -> Data {
        guard let payload, payload.utf8.count <= ((RuntimeLimits.payloadBytes + 2) / 3) * 4,
              let data = Data(base64Encoded: payload), data.count <= RuntimeLimits.payloadBytes else {
            throw RuntimeIssue.invalidFrame
        }
        return data
    }
}

/// Incremental bounded line parser; never accumulates an unbounded stdout stream.
struct Lines {
    private var pending = Data()
    var hasPartial: Bool { !pending.isEmpty }

    mutating func append(_ bytes: Data, consume: (Data) throws -> Void) throws {
        var start = bytes.startIndex
        while start < bytes.endIndex {
            let end = bytes[start...].firstIndex(of: 10) ?? bytes.endIndex
            guard pending.count + (end - start) <= RuntimeLimits.frameBytes else {
                throw RuntimeIssue.oversizedPayload
            }
            pending.append(bytes[start..<end])
            if end == bytes.endIndex { break }
            let line = pending
            pending = Data()
            try consume(line)
            start = end + 1
        }
    }
}
