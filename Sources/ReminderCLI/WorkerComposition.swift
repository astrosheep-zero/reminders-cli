import Foundation
import ReminderCore
import ReminderRuntime

/// Deterministic seam exercises the real Core engine; tests inject a conforming in-memory backend.
/// Production only constructs Native in the worker, never in the parsing/frontend path.
struct WorkerComposition {
    var backend: () throws -> any ReminderBackend
    var diagnose: (Bool) throws -> Diagnostics
    var authorize: () throws -> Void
    var journalURL: URL = DeletionJournal.defaultURL

    func execute(_ request: WorkerRequest, beforeMutation: @escaping () throws -> Void) -> WorkerResponse {
        do {
            switch request {
            case .operation(let command):
                return .operation(Operations(backend: try backend(), journalURL: journalURL, onMutation: beforeMutation).execute(command))
            case .doctor: return .diagnostics(try diagnose(true))
            case .setup:
                // Permission state may change even if the worker dies while the OS prompt is open.
                try beforeMutation()
                do { try authorize() }
                catch let error as Failure { return .operation(ExecutionResult(status: error.code == .outcomeUnknown ? .unknown : .failed, error: error)) }
                catch { return .operation(ExecutionResult(status: .unknown, error: Failure(.outcomeUnknown, "Authorization result unavailable: \(error)"))) }
                return .diagnostics(try diagnose(false))
            }
        } catch {
            let failure = error as? Failure ?? Failure(.backend, String(describing: error))
            return .operation(ExecutionResult(status: failure.code == .outcomeUnknown ? .unknown : .failed, error: failure))
        }
    }
}

enum BuildIdentity {
    /// Runtime resolves this exact same executable. Development identity is deterministic, not a signing identity.
    static var current: String {
        (Bundle.main.object(forInfoDictionaryKey: "ReminderBuildID") as? String) ?? "reminders-poc-development-v1"
    }
    static var notes: [String] {
        ["Local acceptance is not proof of remote iCloud delivery.",
         "Private API support is macOS-version dependent; no live native behavior has been verified automatically.",
         "Ad-hoc rebuilds may lose TCC consent. No permission prompts occur except explicit setup."]
    }
    static var sandbox: String {
        switch SandboxState.current {
        case .sandboxed: "sandboxed"
        case .notSandboxed: "notSandboxed"
        case .unknown: "unknown"
        }
    }
}
