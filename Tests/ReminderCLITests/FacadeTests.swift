import Foundation
import Testing
import ReminderCore
import ReminderRuntime
@testable import ReminderFacade

struct FacadeTests {
    func arguments(_ text: String) throws -> [String: JSONValue] { try JSONDecoder().decode([String: JSONValue].self, from: Data(text.utf8)) }
    @Test func everyOperationHasStableSchemaAndTypedDispatch() throws {
        let samples: [(String, String, WorkerRequest)] = [
            ("doctor", "{}", .doctor),
            ("find", #"{"query":{"includeCompleted":true},"limit":2}"#, .operation(.find({ var q = ReminderQuery(); q.includeCompleted = true; q.limit = 2; return q }()))),
            ("show", #"{"id":"R"}"#, .operation(.show("R"))),
            ("add", #"{"title":"T","list":"L"}"#, .operation(.create(ReminderDraft(fields: ReminderFields(title: "T", listID: "L"))))),
            ("edit", #"{"id":"R","version":"V","set":{"flagged":false},"clear":["due"]}"#, .operation(.update(id: "R", version: "V", patch: { var p = ReminderPatch(); p.flagged = .set(false); p.due = .clear; return p }()))),
            ("done", #"{"id":"R","version":"V","undo":true}"#, .operation(.complete(id: "R", version: "V", completed: false))),
            ("delete", #"{"id":"R","version":"V"}"#, .operation(.delete(id: "R", version: "V"))),
            ("deleted", "{}", .operation(.deleted)), ("catalog", "{}", .operation(.catalog(includeTags: true))),
            ("restore", #"{"id":"R","list":"L"}"#, .operation(.restore(id: "R", list: "L"))),
            ("image", #"{"id":"R","imageID":"I"}"#, .operation(.image(reminderID: "R", imageID: "I"))),
            ("lists_add", #"{"name":"N"}"#, .operation(.list(.create(ListFields(name: "N"))))),
            ("lists_edit", #"{"id":"L","fields":{"name":"N","pinned":false,"kind":"standard","sort":"manual"}}"#, .operation(.list(.update("L", ListFields(name: "N"))))),
            ("lists_delete", #"{"id":"L","confirmed":true}"#, .operation(.list(.delete("L", confirmed: true)))),
            ("lists_clear_completed", #"{"id":"L","confirmed":true}"#, .operation(.list(.clearCompleted("L", confirmed: true)))),
            ("groups_add", #"{"name":"N"}"#, .operation(.group(.create("N")))),
            ("groups_rename", #"{"id":"G","name":"N"}"#, .operation(.group(.rename("G", name: "N")))),
            ("groups_delete", #"{"id":"G","confirmed":true}"#, .operation(.group(.delete("G", confirmed: true)))),
            ("sections_add", #"{"name":"N","list":"L"}"#, .operation(.section(.create(list: "L", name: "N")))),
            ("sections_rename", #"{"id":"S","list":"L","name":"N"}"#, .operation(.section(.rename(list: "L", section: "S", name: "N")))),
            ("sections_move", #"{"id":"S","list":"L","position":{"kind":"after","value":"A"}}"#, .operation(.section(.move(list: "L", section: "S", position: .after("A"))))),
            ("sections_delete", #"{"id":"S","list":"L","confirmed":true}"#, .operation(.section(.delete(list: "L", section: "S", confirmed: true)))),
            ("tags_rename", #"{"id":"old","name":"new"}"#, .operation(.tag(.rename("old", name: "new")))),
            ("tags_delete", #"{"id":"tag","confirmed":true}"#, .operation(.tag(.delete("tag", confirmed: true)))),
            ("smart_lists_add", #"{"name":"N","definition":{"filters":[{"kind":"flagged","value":true}]}}"#, .operation(.smartList(.create(SmartList(id: "", name: "N", filters: [.flagged(true)]))))),
            ("smart_lists_edit", #"{"id":"S","definition":{"id":"S","name":"N","match":"all","filters":[]}}"#, .operation(.smartList(.update("S", SmartList(id: "S", name: "N"))))),
            ("smart_lists_delete", #"{"id":"S","confirmed":true}"#, .operation(.smartList(.delete("S", confirmed: true)))),
            ("templates_add", #"{"name":"N","list":"L","includeCompleted":true}"#, .operation(.template(.create(name: "N", list: "L", includeCompleted: true)))),
            ("templates_use", #"{"id":"T","name":"N"}"#, .operation(.template(.use("T", newListName: "N")))),
            ("templates_delete", #"{"id":"T","confirmed":true}"#, .operation(.template(.delete("T", confirmed: true))))
        ]
        var tested = Set<String>()
        for (name, json, request) in samples {
            #expect(try FacadeOperations.prepare(name, arguments: arguments(json)).request == request); tested.insert(name)
        }
        for family in ["lists", "groups", "sections", "tags", "smart_lists", "templates"] {
            let prepared = try FacadeOperations.prepare(family, arguments: [:])
            #expect(prepared.request == .operation(.catalog(includeTags: family == "tags")))
            #expect(prepared.projection == family.replacingOccurrences(of: "_", with: "-")); tested.insert(family)
        }
        let definitions = FacadeOperations.definitions
        #expect(Set(definitions.map(\.toolName)) == tested)
        #expect(definitions.count == tested.count)
        #expect(!tested.contains("setup"))
        for definition in definitions {
            let schema = try JSONValue.properties(definition.inputSchema)
            #expect(schema["type"] == .string("object")); #expect(schema["additionalProperties"] == .bool(false))
            #expect(!definition.summary.isEmpty)
        }
    }
    @Test func schemaRejectsUnknownNullInternalEnumsAndMissingReplacementFields() throws {
        let samples: [(String, String)] = [
            ("setup", "{}"), ("show", #"{"id":"R","setup":true}"#), ("show", #"{"id":null}"#),
            ("edit", #"{"id":"R","version":"V","set":{"notes":null}}"#),
            ("edit", #"{"id":"R","version":"V","set":{"due":{"date":{"_0":{"year":2030,"month":1,"day":1}}}}}"#),
            ("edit", #"{"id":"R","version":"V","set":{"due":{"kind":"date","value":{"year":2030,"month":1,"day":1,"unknown":2}}}}"#),
            ("edit", #"{"id":"R","version":"V","set":{"notes":"x"},"clear":["notes"]}"#),
            ("lists_edit", #"{"id":"L","fields":{"name":"N"}}"#), ("lists_delete", #"{"id":"L","confirmed":false}"#),
            ("smart_lists_edit", #"{"id":"S","definition":{"name":"N"}}"#),
            ("smart_lists_add", #"{"name":"N","definition":{"filters":[{"kind":"unknown","key":"x","payload":"AQ=="}]}}"#),
            ("find", #"{"limit":1.5}"#), ("find", #"{"limit":0}"#), ("image", #"{"id":"R"}"#)
        ]
        for (name, text) in samples { #expect(throws: Failure.self) { try FacadeOperations.prepare(name, arguments: arguments(text)) } }
    }
    @Test func outputCodecRoundtripsFieldsWithoutLeakingCoreEnumsAndKeepsVersion() throws {
        var fields = ReminderFields(title: "T", listID: "L", due: .date(CalendarDate(2030, 2, 3)),
            start: .localDateTime(CalendarDate(2030, 2, 2), hour: 9, minute: 30, second: 0),
            recurrence: Recurrence(frequency: .monthly, end: .until(CalendarDate(2031, 1, 1))),
            location: .gettingInCar, position: .before("A"))
        fields.earlyAlerts = [EarlyAlert(before: 1, unit: .days)]
        let item = Reminder(id: "R", fields: fields)
        let output = try Presentation.output(.operation(ExecutionResult(status: .ok, result: .reminders([item]))))
        let encoded = String(decoding: try output.json(), as: UTF8.self)
        #expect(!encoded.contains("_0")); #expect(encoded.contains(#""kind":"localDateTime""#))
        guard case .object(let root) = output.result, case .array(let rows) = root["reminders"], case .object(let row) = rows[0] else { throw invalid("Expected reminder output") }
        #expect(row["version"] == .string(try item.version()))
        let prepared = try FacadeOperations.prepare("edit", arguments: ["id": .string("R"), "version": .string("V"), "set": row["fields"]!])
        guard case .operation(.update(_, _, let patch)) = prepared.request else { throw invalid("Expected update") }
        #expect(try patch.applying(to: ReminderFields(title: "old", listID: "old")) == fields)
        let smart = SmartList(id: "S", name: "N", filters: [.date(.relative(past: 0, future: 7, unit: .days)), .unknown(key: "native", payload: Data([1]))])
        let catalog = Catalog(lists: [ReminderList(id: "L", fields: ListFields(name: "N", position: .after("B")))],
            sections: [Section(id: "A", name: "N", listID: "L", position: .before("B"))], smartLists: [smart])
        for projection: String? in [nil, "lists", "sections:L", "smart-lists"] {
            let result = try Presentation.output(.operation(ExecutionResult(status: .ok, result: .catalog(catalog))), projection: projection)
            let text = String(decoding: try result.json(), as: UTF8.self)
            #expect(!text.contains("_0"))
            if projection == nil || projection == "smart-lists" { #expect(text.contains(#""kind":"unknown""#)); #expect(text.contains("AQ==")) }
        }
    }
    @Test func invalidCallNeverSpawnsAndCancelledMutationNeverBecomesDefiniteFailure() async throws {
        let fixture = try FrontendFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        for mode in ["before", "after"] {
            let artifact = fixture.directory.appendingPathComponent(mode)
            let facade = RemindersFacade(client: RuntimeClient(executable: fixture.executable, arguments: ["worker", artifact.path, mode]), buildID: "fixture-signal")
            let bad = await facade.call("setup", arguments: [:])
            #expect(bad.error?.code == .invalidInput); #expect(!FileManager.default.fileExists(atPath: artifact.path))
            let task = Task { await facade.call("add", arguments: ["title": .string("T"), "list": .string("L")]) }
            let pid = try await awaitFixturePID(artifact)
            task.cancel()
            let result = await task.value
            #expect(result.status == (mode == "after" ? .unknown : .failed))
            #expect(result.exitStatus == (mode == "after" ? 5 : 6))
            #expect(kill(pid, 0) == -1); #expect(errno == ESRCH)
            await facade.shutdown()
        }
    }
    @Test func pendingCancellationAndShutdownNeverLaunchQueuedWorker() async throws {
        let fixture = try FrontendFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let artifact = fixture.directory.appendingPathComponent("queue")
        let facade = RemindersFacade(client: RuntimeClient(executable: fixture.executable, arguments: ["worker", artifact.path, "after"]), buildID: "fixture-signal")
        let first = Task { await facade.call("show", arguments: ["id": .string("R")]) }
        let pid = try await awaitFixturePID(artifact)
        let pending = Task { await facade.call("show", arguments: ["id": .string("S")]) }
        pending.cancel()
        // SDK receive/cancel work remains runnable while the first Runtime call blocks its serial queue.
        try await Task.sleep(for: .milliseconds(50))
        #expect(try String(contentsOf: artifact, encoding: .utf8) == String(pid))
        try FileManager.default.removeItem(at: artifact)
        await facade.shutdown()
        let firstResult = await first.value, pendingResult = await pending.value
        #expect(firstResult.status == .unknown); #expect(pendingResult.status == .failed)
        #expect(!FileManager.default.fileExists(atPath: artifact.path)); #expect(kill(pid, 0) == -1)
        let later = await facade.call("show", arguments: ["id": .string("T")])
        #expect(later.status == .failed); #expect(!FileManager.default.fileExists(atPath: artifact.path))
    }
}

func awaitFixturePID(_ file: URL) async throws -> Int32 {
    let deadline = ProcessInfo.processInfo.systemUptime + 8
    while !FileManager.default.fileExists(atPath: file.path), ProcessInfo.processInfo.systemUptime < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    return try #require(Int32(String(contentsOf: file, encoding: .utf8)))
}
