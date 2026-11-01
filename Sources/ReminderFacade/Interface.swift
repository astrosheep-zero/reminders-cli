import Foundation
import ReminderCore
import ReminderRuntime

/// Facade owns the opaque Runtime payload. Neither frontend constructs Native.
public enum WorkerRequest: Codable, Sendable, Equatable {
    case operation(Command), setup, doctor
}
public struct DiagnosticCheck: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case passed, failed, skipped, unverified }
    public var status: Status
    public var message: String
    public var error: Failure?
    public init(status: Status, message: String, error: Failure? = nil) { self.status = status; self.message = message; self.error = error }
}
public struct Diagnostics: Codable, Sendable, Equatable {
    public var authorization: String
    public var sandbox: String
    public var buildID: String
    public var capabilities: [String]
    public var notes: [String]
    public var bundle: DiagnosticCheck = .init(status: .unverified, message: "Bundle not inspected")
    public var signature: DiagnosticCheck = .init(status: .unverified, message: "Signature not inspected")
    public var readProbe: DiagnosticCheck = .init(status: .skipped, message: "Read probe not requested")
    public var tccOwnership: DiagnosticCheck = .init(status: .unverified, message: "Static authorization and a read probe do not independently verify macOS TCC ownership attribution")
    public init(authorization: String, sandbox: String, buildID: String, capabilities: [String], notes: [String]) {
        self.authorization = authorization; self.sandbox = sandbox; self.buildID = buildID; self.capabilities = capabilities; self.notes = notes
    }
}
public enum WorkerResponse: Codable, Sendable {
    case operation(ExecutionResult), diagnostics(Diagnostics)

    func validate(for request: WorkerRequest, mutationStarted: Bool) throws {
        switch (request, self) {
        case (.setup, .diagnostics), (.doctor, .diagnostics): return
        case (.setup, .operation(let output)), (.doctor, .operation(let output)):
            guard output.status != .ok else { throw invalid("Unexpected operation result for diagnostics request") }
        case (.operation(let command), .operation(let output)):
            guard !(mutationStarted && output.status == .failed) else { throw invalid("Definite failure contradicts mutation marker") }
            guard output.status == .ok else { return }
            switch (command, output.result) {
            case (.catalog(let requested, _), .catalog(_, let returned)) where requested == returned: return
            case (.find, .reminders), (.show, .reminders), (.deleted, .deleted), (.image, .image): return
            case (.create, .mutation), (.update, .mutation), (.complete, .mutation), (.delete, .mutation),
                 (.restore, .mutation), (.list, .mutation), (.group, .mutation), (.section, .mutation),
                 (.tag, .mutation), (.smartList, .mutation), (.template, .mutation): return
            default: throw invalid("Worker returned the wrong typed result for its command")
            }
        default: throw invalid("Worker returned diagnostics for an operation")
        }
    }
}
public struct OutputEnvelope: Codable, Sendable {
    public var status: ExecutionResult.Status
    public var result: JSONValue?
    public var error: Failure?
    public var warnings: [String]
    public init(status: ExecutionResult.Status, result: JSONValue? = nil, error: Failure? = nil, warnings: [String] = []) {
        self.status = status; self.result = result; self.error = error; self.warnings = warnings
    }
    public var exitStatus: Int32 { Int32(error?.code.exitStatus ?? (status == .ok ? 0 : 6)) }
    public static func failure(_ failure: Failure, warnings: [String] = []) -> Self {
        Self(status: failure.code == .outcomeUnknown ? .unknown : .failed, error: failure, warnings: warnings)
    }
    public static func unknown(_ message: String) -> Self {
        .failure(Failure(.outcomeUnknown, message), warnings: ["The operation may have taken effect. Do not blindly retry writes; inspect state first."])
    }
    public func json() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public enum Presentation {
    public static func value<T: Encodable>(_ input: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(input))
    }
    static func body<T: Encodable>(_ kind: String, _ input: T) throws -> JSONValue {
        .object(["kind": .string(kind), kind: try value(input)])
    }
    private static func mapped<T: Encodable>(_ input: T, key: String, schema: Schema, extra: [String: JSONValue] = [:]) throws -> JSONValue {
        var result = try JSONValue.properties(input).merging(extra) { _, new in new }
        if let value = result[key] { result[key] = try schema.convert(value, outward: true) }
        return .object(result)
    }
    static func reminder(_ input: Reminder) throws -> JSONValue {
        try mapped(input, key: "fields", schema: Shapes.fields, extra: ["version": .string(input.version())])
    }
    public static func output(_ response: WorkerResponse) throws -> OutputEnvelope {
        switch response {
        case .diagnostics(let diagnostic):
            return OutputEnvelope(status: .ok, result: try body("diagnostics", diagnostic), warnings: diagnostic.notes)
        case .operation(let response):
            // Treat malformed success/failure combinations as a corrupted final answer, never no-write.
            switch response.status {
            case .ok: guard response.result != nil, response.error == nil else { throw invalid("Malformed successful result") }
            case .failed: guard let error = response.error, error.code != .outcomeUnknown else { throw invalid("Malformed failed result") }
            case .unknown: guard response.error?.code == .outcomeUnknown else { throw invalid("Malformed unknown result") }
            }
            let result = try response.result.map { result -> JSONValue in
                switch result {
                case .reminders(let reminders):
                    return .object(["kind": .string("reminders"), "reminders": .array(try reminders.map(reminder))])
                case .mutation(let mutation):
                    var data = try JSONValue.properties(mutation)
                    data["count"] = .number(Decimal(mutation.count))
                    data["reminders"] = .array(try mutation.reminders.map(reminder))
                    data["lists"] = .array(try mutation.lists.map { try mapped($0, key: "fields", schema: Shapes.list) })
                    return .object(["kind": .string("mutation"), "mutation": .object(data)])
                case .catalog(let catalog, let scope): return try catalogOutput(catalog, scope: scope)
                case .deleted(let deleted):
                    // scope is explicit even if the Core Codable representation changes.
                    return .object(["kind": .string("deleted"), "scope": .string("toolOnly"), "entries": try value(deleted.entries)])
                case .image(let image): return try body("image", image)
                }
            }
            var warnings = response.warnings
            if response.status == .unknown && warnings.isEmpty {
                warnings.append("The operation may have taken effect. Do not blindly retry writes; inspect state first.")
            }
            return OutputEnvelope(status: response.status, result: result, error: response.error, warnings: warnings)
        }
    }
    private static func catalogOutput(_ catalog: Catalog, scope: CatalogScope) throws -> JSONValue {
        var result = try JSONValue.properties(catalog)
        result["lists"] = .array(try catalog.lists.map { try mapped($0, key: "fields", schema: Shapes.list) })
        result["sections"] = .array(try catalog.sections.map { try mapped($0, key: "position", schema: Shapes.position) })
        result["smartLists"] = .array(try catalog.smartLists.map { try Shapes.smart.convert(value($0), outward: true) })
        return scope == .all ? .object(["kind": .string("catalog"), "catalog": .object(result)])
            : .object(["kind": .string(scope.rawValue), scope.rawValue: result[scope.rawValue]!])
    }

    public static func transportOutcome(_ outcome: RuntimeReply.Outcome, mutationStarted: Bool = false,
                                 request: WorkerRequest? = nil) -> OutputEnvelope {
        switch outcome {
        case .result(let data):
            do {
                let response = try JSONDecoder().decode(WorkerResponse.self, from: data)
                if let request { try response.validate(for: request, mutationStarted: mutationStarted) }
                return try self.output(response)
            } catch {
                let message = "Worker's final typed result could not be decoded or validated: \(error)"
                return mutationStarted ? .unknown(message) : .failure(Failure(.backend, message))
            }
        case .outcomeUnknown(let issue): return .unknown("Worker transport lost the final answer: \(issue)")
        case .failed(let issue):
            let code: ErrorCode
            switch issue {
            case .spawnRefused(_, let disclaim): code = disclaim ? .sandbox : .io
            case .oversizedPayload, .invalidConfiguration: code = .invalidInput
            default: code = .io
            }
            return .failure(Failure(code, "Worker transport failed before mutation: \(issue)"))
        }
    }

    public static func transport(_ reply: RuntimeReply, request: WorkerRequest) -> OutputEnvelope {
        var result = transportOutcome(reply.outcome, mutationStarted: reply.mutationStarted, request: request)
        if let issue = reply.issue {
            if case .result = reply.outcome { result.warnings.append("A final response was received, but transport also reported: \(issue)") }
            else { result.warnings.append("Worker transport reported: \(issue)") }
        }
        if reply.diagnosticsTruncated { result.warnings.append("Worker stderr diagnostics were truncated at 64 KiB.") }
        return result
    }
}
