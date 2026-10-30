import Foundation
import ReminderCore
import ReminderRuntime

/// CLI owns the opaque Runtime payload. Runtime never imports Core or knows command semantics.
enum WorkerRequest: Codable {
    case operation(Command), setup, doctor
}
struct DiagnosticCheck: Codable, Equatable {
    enum Status: String, Codable { case passed, failed, skipped, unverified }
    var status: Status
    var message: String
    var error: Failure? = nil
}
struct Diagnostics: Codable, Equatable {
    var authorization: String
    var sandbox: String
    var buildID: String
    var capabilities: [String]
    var notes: [String]
    var bundle: DiagnosticCheck = .init(status: .unverified, message: "Bundle not inspected")
    var signature: DiagnosticCheck = .init(status: .unverified, message: "Signature not inspected")
    var readProbe: DiagnosticCheck = .init(status: .skipped, message: "Read probe not requested")
    var tccOwnership: DiagnosticCheck = .init(status: .unverified, message: "Static authorization and a read probe do not independently verify macOS TCC ownership attribution")
}
enum WorkerResponse: Codable {
    case operation(ExecutionResult), diagnostics(Diagnostics)

    func validate(for request: WorkerRequest, mutationStarted: Bool) throws {
        switch (request, self) {
        case (.setup, .diagnostics), (.doctor, .diagnostics): return
        case (.setup, .operation(let output)), (.doctor, .operation(let output)):
            guard output.status != .ok else { throw CLIParser.invalid("Unexpected operation result for diagnostics request") }
        case (.operation(let command), .operation(let output)):
            guard !(mutationStarted && output.status == .failed) else { throw CLIParser.invalid("Definite failure contradicts mutation marker") }
            guard output.status == .ok else { return }
            switch (command, output.result) {
            case (.find, .reminders), (.show, .reminders), (.catalog, .catalog), (.deleted, .deleted), (.image, .image): return
            case (.create, .mutation), (.update, .mutation), (.complete, .mutation), (.delete, .mutation),
                 (.restore, .mutation), (.list, .mutation), (.group, .mutation), (.section, .mutation),
                 (.tag, .mutation), (.smartList, .mutation), (.template, .mutation): return
            default: throw CLIParser.invalid("Worker returned the wrong typed result for its command")
            }
        default: throw CLIParser.invalid("Worker returned diagnostics for an operation")
        }
    }
}
struct OutputEnvelope: Encodable {
    var status: ExecutionResult.Status
    var result: JSONValue?
    var error: Failure?
    var warnings: [String]
    var exitStatus: Int32 { Int32(error?.code.exitStatus ?? (status == .ok ? 0 : 6)) }
    static func failure(_ failure: Failure, warnings: [String] = []) -> Self {
        Self(status: failure.code == .outcomeUnknown ? .unknown : .failed, error: failure, warnings: warnings)
    }
    static func unknown(_ message: String) -> Self {
        .failure(Failure(.outcomeUnknown, message), warnings: ["The operation may have taken effect. Do not blindly retry writes; inspect state first."])
    }
    func json() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
    func text() throws -> String {
        if let error {
            let affected = error.affectedIDs.isEmpty ? "" : "affectedIDs: \(error.affectedIDs.joined(separator: ", "))\n"
            return "\(status.rawValue): \(error.code.rawValue): \(error.message)\n" + affected + warnings.map { "warning: \($0)\n" }.joined()
        }
        guard let result else { return "ok\n" }
        return HumanOutput.render(result) + warnings.map { "warning: \($0)\n" }.joined()
    }
}

enum Presentation {
    static func value<T: Encodable>(_ input: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(input))
    }
    static func body<T: Encodable>(_ kind: String, _ input: T) throws -> JSONValue {
        .object(["kind": .string(kind), kind: try value(input)])
    }
    static func reminder(_ input: Reminder) throws -> JSONValue {
        var object = try JSONValue.properties(input); object["version"] = .string(try input.version())
        return .object(object)
    }
    static func output(_ response: WorkerResponse, projection: String? = nil) throws -> OutputEnvelope {
        switch response {
        case .diagnostics(let diagnostic):
            return OutputEnvelope(status: .ok, result: try body("diagnostics", diagnostic), warnings: diagnostic.notes)
        case .operation(let response):
            // Treat malformed success/failure combinations as a corrupted final answer, never no-write.
            switch response.status {
            case .ok: guard response.result != nil, response.error == nil else { throw CLIParser.invalid("Malformed successful result") }
            case .failed: guard let error = response.error, error.code != .outcomeUnknown else { throw CLIParser.invalid("Malformed failed result") }
            case .unknown: guard response.error?.code == .outcomeUnknown else { throw CLIParser.invalid("Malformed unknown result") }
            }
            let result = try response.result.map { result -> JSONValue in
                switch result {
                case .reminders(let reminders):
                    return .object(["kind": .string("reminders"), "reminders": .array(try reminders.map(reminder))])
                case .mutation(let mutation):
                    var data = try JSONValue.properties(mutation)
                    data["count"] = .number(Decimal(mutation.count))
                    data["reminders"] = .array(try mutation.reminders.map(reminder))
                    return .object(["kind": .string("mutation"), "mutation": .object(data)])
                case .catalog(let catalog): return try catalogOutput(catalog, projection: projection)
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
    private static func catalogOutput(_ catalog: Catalog, projection: String?) throws -> JSONValue {
        guard let projection else { return try body("catalog", catalog) }
        let pieces = projection.split(separator: ":", maxSplits: 1).map(String.init)
        switch pieces[0] {
        case "lists": return try body("lists", catalog.lists)
        case "groups": return try body("groups", catalog.groups)
        case "tags": return try body("tags", catalog.tags)
        case "smart-lists": return try body("smartLists", catalog.smartLists)
        case "templates": return try body("templates", catalog.templates)
        case "sections":
            var sections = catalog.sections
            if pieces.count == 2 {
                let input = pieces[1]
                let ids = catalog.lists.filter { $0.id.caseInsensitiveCompare(input) == .orderedSame }
                let matches = ids.isEmpty ? catalog.lists.filter { $0.fields.name == input } : ids
                guard matches.count == 1 else { throw Failure(matches.isEmpty ? .notFound : .ambiguous, "No unique list: \(input)") }
                sections = sections.filter { $0.listID.caseInsensitiveCompare(matches[0].id) == .orderedSame }
            }
            return try body("sections", sections)
        default: throw CLIParser.invalid("Unknown catalog projection")
        }
    }

    static func transportOutcome(_ outcome: RuntimeReply.Outcome, mutationStarted: Bool = false,
                                 request: WorkerRequest? = nil, projection: String? = nil) -> OutputEnvelope {
        switch outcome {
        case .result(let data):
            do {
                let response = try JSONDecoder().decode(WorkerResponse.self, from: data)
                if let request { try response.validate(for: request, mutationStarted: mutationStarted) }
                return try self.output(response, projection: projection)
            }
            catch let failure as Failure where failure.code == .notFound || failure.code == .ambiguous {
                return .failure(failure)
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

    static func transport(_ reply: RuntimeReply, request: WorkerRequest, projection: String? = nil) -> OutputEnvelope {
        var result = transportOutcome(reply.outcome, mutationStarted: reply.mutationStarted, request: request, projection: projection)
        if let issue = reply.issue {
            if case .result = reply.outcome { result.warnings.append("A final response was received, but transport also reported: \(issue)") }
            else { result.warnings.append("Worker transport reported: \(issue)") }
        }
        if reply.diagnosticsTruncated { result.warnings.append("Worker stderr diagnostics were truncated at 64 KiB.") }
        return result
    }
}
