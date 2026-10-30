import Testing
import Foundation
import ReminderCore
import ReminderRuntime
@testable import ReminderCLI

/// Implements the current Core protocol, not a compatibility API or a native-behavior claim.
private final class FixtureBackend: ReminderBackend {
    var item = Reminder(id: "fixture-id", fields: ReminderFields(title: "Fixture", listID: "fixture-list"))
    var saved = 0
    var throwsAfterSave = false
    var deleted = false
    func checkSupport(for command: Command) throws {}
    func catalog(includeTags: Bool) throws -> Catalog { Catalog(lists: [ReminderList(id: "fixture-list", fields: ListFields(name: "Fixture list"))]) }
    func reminder(id: String) throws -> Reminder? { id == item.id && !deleted ? item : nil }
    func find(_ query: ReminderQuery) throws -> [Reminder] { deleted ? [] : [item] }
    func createReminder(_ draft: ReminderDraft) throws -> MutationResult {
        item.fields = draft.fields; saved += 1
        return MutationResult(affectedIDs: [item.id], reminders: [item])
    }
    func restorableState(id: String) throws -> RestorableState { deleted ? .restorable : .active }
    func deleteReminders(ids: [String]) throws -> MutationResult {
        deleted = true; saved += 1
        return MutationResult(affectedIDs: ids)
    }
    func restoreReminder(id: String, listID: String, knownChildIDs: [String]) throws -> MutationResult {
        item.fields.listID = listID; deleted = false; saved += 1
        return MutationResult(affectedIDs: [id], reminders: [item])
    }
    func updateReminder(id: String, patch: ReminderPatch) throws -> MutationResult {
        item.fields = try patch.applying(to: item.fields); saved += 1
        if throwsAfterSave { throw Failure(.backend, "Fixture lost save acknowledgement") }
        return MutationResult(affectedIDs: [id], reminders: [item])
    }
}

struct CompositionTests {
    private func composition(_ backend: FixtureBackend) -> WorkerComposition {
        WorkerComposition(backend: { backend }, diagnose: { _ in
            Diagnostics(authorization: "notDetermined", sandbox: "notSandboxed", buildID: "fixture", capabilities: ["fixture"], notes: [])
        }, authorize: { throw Failure(.permission, "Fixture denied") },
        journalURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused-fixture-\(UUID()).json"))
    }
    @Test func parserToSerializedWorkerCoreAndVersionedOutput() throws {
        let backend = FixtureBackend()
        let invocation = try CLIParser.parse(["edit", backend.item.id, "--version", backend.item.version(), "--set-json", #"{"notes":"hello"}"#])
        guard case .operation(let command, _) = invocation.request else { throw CLIParser.invalid("Expected operation") }
        let request = try JSONDecoder().decode(WorkerRequest.self, from: JSONEncoder().encode(WorkerRequest.operation(command)))
        var callbacks = 0
        let response = composition(backend).execute(request, beforeMutation: { callbacks += 1; #expect(backend.saved == 0) })
        let output = Presentation.transportOutcome(.result(try JSONEncoder().encode(response)), mutationStarted: true, request: request)
        #expect(callbacks == 1); #expect(backend.saved == 1); #expect(backend.item.fields.notes == "hello")
        #expect(output.exitStatus == 0)
        guard case .object(let body) = output.result, case .object(let mutation) = body["mutation"],
              case .array(let reminders) = mutation["reminders"], case .object(let item) = reminders.first else { throw CLIParser.invalid("Expected mutation output") }
        #expect(item["version"] == .string(try backend.item.version()))
        #expect(mutation["count"] == .number(1))
    }
    @Test func fixtureCRUDDeletionJournalAndRestoreRoundtrip() throws {
        let backend = FixtureBackend()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cli-crud-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var worker = composition(backend); worker.journalURL = directory.appendingPathComponent("deleted.json")
        var mutations = 0
        func run(_ args: [String]) throws -> OutputEnvelope {
            guard case .operation(let command, _) = try CLIParser.parse(args).request else { throw CLIParser.invalid("Expected operation") }
            let response = worker.execute(.operation(command), beforeMutation: { mutations += 1 })
            return Presentation.transportOutcome(.result(try JSONEncoder().encode(response)), mutationStarted: mutations > 0, request: .operation(command))
        }
        #expect(try run(["add", "New fixture", "--list", "fixture-list"]).exitStatus == 0)
        #expect(try run(["show", backend.item.id]).exitStatus == 0)
        #expect(try run(["edit", backend.item.id, "--version", backend.item.version(), "--set-json", #"{"notes":"edited"}"#]).exitStatus == 0)
        #expect(try run(["done", backend.item.id, "--version", backend.item.version()]).exitStatus == 0)
        #expect(backend.item.fields.completed)
        #expect(try run(["delete", backend.item.id, "--version", backend.item.version()]).exitStatus == 0)
        #expect(backend.deleted)
        let journal = try DeletionJournal(url: worker.journalURL).read()
        #expect(journal.count == 1); #expect(journal.first?.state == .confirmed)
        #expect(try run(["deleted"]).exitStatus == 0)
        #expect(try run(["restore", backend.item.id]).exitStatus == 0)
        #expect(!backend.deleted); #expect(backend.item.fields.notes == "edited")
        #expect(try DeletionJournal(url: worker.journalURL).read().isEmpty)
        #expect(mutations == 5)
    }
    @Test func staleVersionHasNoMutationCallbackOrSave() throws {
        let backend = FixtureBackend(); var callbacks = 0
        let response = composition(backend).execute(.operation(.complete(id: backend.item.id, version: "stale", completed: true)), beforeMutation: { callbacks += 1 })
        let output = try Presentation.output(response)
        #expect(output.error?.code == .conflict); #expect(output.exitStatus == 2)
        #expect(callbacks == 0); #expect(backend.saved == 0)
    }
    @Test func lostSaveAcknowledgementAndMalformedFinalAnswerStayUnknown() throws {
        let backend = FixtureBackend(); backend.throwsAfterSave = true
        let command = Command.complete(id: backend.item.id, version: try backend.item.version(), completed: true)
        let response = composition(backend).execute(.operation(command), beforeMutation: {})
        let output = Presentation.transportOutcome(.result(try JSONEncoder().encode(response)), mutationStarted: true, request: .operation(command))
        #expect(output.status == .unknown); #expect(output.exitStatus == 5); #expect(backend.saved == 1)
        #expect(Presentation.transportOutcome(.result(Data("garbled".utf8)), mutationStarted: true).exitStatus == 5)
        #expect(Presentation.transportOutcome(.result(Data("garbled".utf8)), mutationStarted: false).exitStatus == 6)
        let malformed = WorkerResponse.operation(ExecutionResult(status: .ok))
        #expect(Presentation.transportOutcome(.result(try JSONEncoder().encode(malformed)), mutationStarted: true).exitStatus == 5)
        #expect(Presentation.transportOutcome(.outcomeUnknown(.deadline)).exitStatus == 5)
        #expect(Presentation.transportOutcome(.failed(.buildMismatch)).exitStatus == 6)
        #expect(Presentation.transportOutcome(.failed(.spawnRefused(code: 1, disclaim: true))).exitStatus == 3)
        #expect(Presentation.transportOutcome(.failed(.oversizedPayload)).exitStatus == 1)
        let wrongKind = WorkerResponse.operation(ExecutionResult(status: .ok, result: .catalog(Catalog())))
        #expect(Presentation.transportOutcome(.result(try JSONEncoder().encode(wrongKind)), mutationStarted: true, request: .operation(command)).exitStatus == 5)
        let contradiction = WorkerResponse.operation(ExecutionResult(status: .failed, error: Failure(.backend, "Contradicts marker")))
        #expect(Presentation.transportOutcome(.result(try JSONEncoder().encode(contradiction)), mutationStarted: true, request: .operation(command)).exitStatus == 5)
    }
    @Test func doctorDoesNotConstructBackendOrAuthorize() throws {
        let denied = try Presentation.output(composition(FixtureBackend()).execute(.setup, beforeMutation: {}))
        #expect(denied.error?.code == .permission); #expect(denied.exitStatus == 3)
        var backendCalls = 0, authCalls = 0, mutations = 0
        var fixture = composition(FixtureBackend())
        fixture.backend = { backendCalls += 1; throw Failure(.backend, "Must not open store") }
        fixture.authorize = { authCalls += 1 }
        let output = try Presentation.output(fixture.execute(.doctor, beforeMutation: { mutations += 1 }))
        #expect(output.status == .ok)
        #expect(backendCalls == 0); #expect(authCalls == 0); #expect(mutations == 0)
        let setup = try Presentation.output(fixture.execute(.setup, beforeMutation: { mutations += 1 }))
        #expect(setup.status == .ok); #expect(authCalls == 1); #expect(mutations == 1); #expect(backendCalls == 0)
    }
    @Test func JSONEnvelopeDeletedScopeAndStableErrors() throws {
        let response = WorkerResponse.operation(ExecutionResult(status: .ok, result: .deleted(DeletedResult(entries: []))))
        let output = try Presentation.output(response)
        let data = try JSONDecoder().decode(JSONValue.self, from: output.json())
        guard case .object(let root) = data, case .object(let body) = root["result"] else { throw CLIParser.invalid("Expected envelope") }
        #expect(root["status"] == .string("ok")); #expect(root["warnings"] == .array([]))
        #expect(body["scope"] == .string("toolOnly"))
        let statuses: [(ErrorCode, Int32)] = [(.invalidInput, 1), (.notFound, 2), (.ambiguous, 2), (.conflict, 2), (.permission, 3), (.sandbox, 3), (.unsupported, 4), (.outcomeUnknown, 5), (.backend, 6), (.io, 6), (.internal, 6)]
        for (code, exit) in statuses {
            let error = OutputEnvelope.failure(Failure(code, "Fixture"))
            #expect(error.exitStatus == exit)
            #expect(error.status == (code == .outcomeUnknown ? .unknown : .failed))
            #expect(String(decoding: try error.json(), as: UTF8.self).contains("\"code\":\"\(code.rawValue)\""))
        }
    }
}
