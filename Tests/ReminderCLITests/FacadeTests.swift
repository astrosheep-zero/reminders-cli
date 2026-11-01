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
            ("find", #"{"includeCompleted":true,"limit":2}"#, .operation(.find({ var q = ReminderQuery(); q.includeCompleted = true; q.limit = 2; return q }()))),
            ("show", #"{"id":"R"}"#, .operation(.show("R"))),
            ("add", #"{"title":"T","list":"L"}"#, .operation(.create(ReminderDraft(fields: ReminderFields(title: "T", listID: "L"))))),
            ("edit", #"{"id":"R","version":"V","set":{"flagged":false},"clear":["due"]}"#, .operation(.update(id: "R", version: "V", patch: { var p = ReminderPatch(); p.flagged = .set(false); p.due = .clear; return p }()))),
            ("done", #"{"id":"R","version":"V","undo":true}"#, .operation(.complete(id: "R", version: "V", completed: false))),
            ("delete", #"{"id":"R","version":"V"}"#, .operation(.delete(id: "R", version: "V"))),
            ("deleted", "{}", .operation(.deleted)), ("catalog", "{}", .operation(.catalog(.all))),
            ("restore", #"{"id":"R","list":"L"}"#, .operation(.restore(id: "R", list: "L"))),
            ("image", #"{"id":"R","imageID":"I"}"#, .operation(.image(reminderID: "R", imageID: "I"))),
            ("lists_add", #"{"name":"N"}"#, .operation(.list(.create(ListFields(name: "N"))))),
            ("lists_edit", #"{"id":"L","set":{"name":"N","pinned":false,"kind":"standard","sort":"manual"}}"#, .operation(.list(.update("L", { var p = ListPatch(); p.name = "N"; p.pinned = false; p.kind = .standard; p.sort = .manual; return p }())))),
            ("lists_delete", #"{"id":"L","confirmed":true}"#, .operation(.list(.delete("L", confirmed: true)))),
            ("lists_clear_completed", #"{"id":"L","confirmed":true}"#, .operation(.list(.clearCompleted("L", confirmed: true)))),
            ("groups_add", #"{"name":"N"}"#, .operation(.group(.create("N")))),
            ("groups_edit", #"{"id":"G","set":{"name":"N"}}"#, .operation(.group(.rename("G", name: "N")))),
            ("groups_delete", #"{"id":"G","confirmed":true}"#, .operation(.group(.delete("G", confirmed: true)))),
            ("sections_add", #"{"name":"N","list":"L"}"#, .operation(.section(.create(list: "L", name: "N")))),
            ("sections_edit", #"{"id":"S","list":"L","set":{"name":"N","position":{"kind":"after","value":"A"}}}"#, .operation(.section(.update(list: "L", section: "S", patch: SectionPatch(name: "N", position: .after("A")))))),
            ("sections_delete", #"{"id":"S","list":"L","confirmed":true}"#, .operation(.section(.delete(list: "L", section: "S", confirmed: true)))),
            ("tags_edit", #"{"tag":"old","set":{"name":"new"}}"#, .operation(.tag(.rename("old", name: "new")))),
            ("tags_delete", #"{"tag":"tag","confirmed":true}"#, .operation(.tag(.delete("tag", confirmed: true)))),
            ("smart_lists_add", #"{"name":"N","fields":{"filters":[{"kind":"flagged","value":true}]}}"#, .operation(.smartList(.create(SmartListDraft(name: "N", filters: [.flagged(true)]))))),
            ("smart_lists_edit", #"{"id":"S","set":{"name":"N"}}"#, .operation(.smartList(.update("S", { var p = SmartListPatch(); p.name = "N"; return p }(), clear: [])))),
            ("smart_lists_delete", #"{"id":"S","confirmed":true}"#, .operation(.smartList(.delete("S", confirmed: true)))),
            ("templates_add", #"{"name":"N","list":"L","includeCompleted":true}"#, .operation(.template(.create(name: "N", list: "L", includeCompleted: true)))),
            ("templates_use", #"{"id":"T","name":"N"}"#, .operation(.template(.use("T", newListName: "N")))),
            ("templates_delete", #"{"id":"T","confirmed":true}"#, .operation(.template(.delete("T", confirmed: true))))
        ]
        var tested = Set<String>()
        for (name, json, request) in samples {
            #expect(try FacadeOperations.prepare(name, arguments: arguments(json)) == request); tested.insert(name)
        }
        for (family, scope): (String, CatalogScope) in [("lists", .lists), ("groups", .groups), ("sections", .sections), ("tags", .tags), ("smart_lists", .smartLists), ("templates", .templates)] {
            #expect(try FacadeOperations.prepare(family, arguments: [:]) == .operation(.catalog(scope)))
            tested.insert(family)
        }
        #expect(try FacadeOperations.prepare("sections", arguments: ["list": .string("A:B")]) == .operation(.catalog(.sections, list: "A:B")))
        let wrongScope = WorkerResponse.operation(ExecutionResult(status: .ok, result: .catalog(Catalog(), scope: .groups)))
        let rejected = Presentation.transportOutcome(.result(try JSONEncoder().encode(wrongScope)), request: .operation(.catalog(.lists)))
        #expect(rejected.status == .failed); #expect(rejected.error?.code == .backend)
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
    @Test func sparseSectionEditUsesOnlySuppliedFieldsAndRejectsInvalidSets() throws {
        #expect(try FacadeOperations.prepare("sections_edit", arguments: arguments(#"{"id":"S","list":"L","set":{"name":"N"}}"#)) == .operation(.section(.update(list: "L", section: "S", patch: SectionPatch(name: "N")))))
        #expect(try FacadeOperations.prepare("sections_edit", arguments: arguments(#"{"id":"S","list":"L","set":{"position":{"kind":"before","value":"A"}}}"#)) == .operation(.section(.update(list: "L", section: "S", patch: SectionPatch(position: .before("A"))))))
        for text in [#"{"id":"S","set":{"name":"N"}}"#, #"{"id":"S","list":"L"}"#,
            #"{"id":"S","list":"L","set":{}}"#, #"{"id":"S","list":"L","set":null}"#,
            #"{"id":"S","list":"L","set":{"name":null}}"#, #"{"id":"S","list":"L","set":{"position":null}}"#,
            #"{"id":"S","list":"L","set":{"name":" "}}"#, #"{"id":"S","list":"L","set":{"position":{"kind":"first","value":"A"}}}"#,
            #"{"id":"S","list":"L","set":{"name":"N"},"clear":["position"]}"#] {
            #expect(throws: Failure.self) { try FacadeOperations.prepare("sections_edit", arguments: arguments(text)) }
        }
    }
    @Test func sparseListAndNativeQueryArgumentsUseTypedCurrentRequests() throws {
        var patch = ListPatch(); patch.name = "Only rename"
        #expect(try FacadeOperations.prepare("lists_edit", arguments: arguments(#"{"id":"L","set":{"name":"Only rename"}}"#)) == .operation(.list(.update("L", patch))))
        #expect(try FacadeOperations.prepare("lists_edit", arguments: arguments(#"{"id":"L","clear":["color","icon","group"]}"#)) == .operation(.list(.update("L", ListPatch(), clear: [.color, .icon, .groupID]))))
        let request = try FacadeOperations.prepare("find", arguments: arguments(#"{"text":"fish","matching":"prefix","tags":["work","home"],"excludeTags":["blocked"],"tagMatch":"any","flagged":false,"limit":12,"offset":4}"#))
        guard case .operation(.find(let query)) = request else { throw invalid("Expected find") }
        #expect(query.text == "fish"); #expect(query.matching == .prefix)
        #expect(query.tags == ["work", "home"]); #expect(query.excludeTags == ["blocked"]); #expect(query.tagMatch == .any)
        #expect(query.flagged == false); #expect(query.limit == 12); #expect(query.offset == 4)
        let edit = try #require(FacadeOperations.definitions.first { $0.toolName == "lists_edit" })
        #expect(try JSONValue.properties(edit.inputSchema)["required"] == .array([.string("id")]))
    }
    @Test func creationAllowsDefaultOrParentAndRejectsDuplicateIdentity() throws {
        let samples = [#"{"title":"T"}"#, #"{"title":"T","fields":{"parent":"P"}}"#, #"{"title":"T","list":"L"}"#]
        for (json, fields) in zip(samples, [ReminderFields(title: "T", listID: ""), ReminderFields(title: "T", listID: "", parentID: "P"), ReminderFields(title: "T", listID: "L")]) {
            #expect(try FacadeOperations.prepare("add", arguments: arguments(json)) == .operation(.create(ReminderDraft(fields: fields))))
        }
        for json in [#"{"title":"T","fields":{"title":"other"}}"#, #"{"title":"T","list":"L","fields":{"listID":"other"}}"#] {
            #expect(throws: Failure.self) { try FacadeOperations.prepare("add", arguments: arguments(json)) }
        }
        let definition = try #require(FacadeOperations.definitions.first { $0.name == "add" })
        #expect(try JSONValue.properties(definition.inputSchema)["required"] == .array([.string("title")]))
    }
    @Test func writeReferencesAndClearRules() throws {
        let create = try FacadeOperations.prepare("add", arguments: arguments(#"{"title":"T","list":"L","fields":{"parent":"P","section":"S","assignee":"me"}}"#))
        #expect(create == .operation(.create(ReminderDraft(fields: ReminderFields(title: "T", listID: "L", parentID: "P", sectionID: "S", assigneeID: "me")))))
        let edit = try FacadeOperations.prepare("edit", arguments: arguments(#"{"id":"R","version":"V","set":{"list":"L","parent":"P","section":"S","assignee":"me"}}"#))
        guard case .operation(.update(_, _, let patch)) = edit else { throw invalid("Expected edit") }
        #expect(patch.listID == .set("L")); #expect(patch.parentID == .set("P"))
        #expect(patch.sectionID == .set("S")); #expect(patch.assigneeID == .set("me"))
        let list = try FacadeOperations.prepare("lists_add", arguments: arguments(#"{"name":"N","fields":{"group":"G"}}"#))
        var fields = ListFields(name: "N"); fields.groupID = "G"
        #expect(list == .operation(.list(.create(fields))))
        let listEdit = try FacadeOperations.prepare("lists_edit", arguments: arguments(#"{"id":"L","set":{"group":"G","pinned":false}}"#))
        var listPatch = ListPatch(); listPatch.groupID = "G"; listPatch.pinned = false
        #expect(listEdit == .operation(.list(.update("L", listPatch))))
        for json in [#"{"id":"R","version":"V","clear":["title"]}"#, #"{"id":"R","version":"V","clear":["list"]}"#, #"{"id":"R","version":"V","clear":["position"]}"#, #"{"id":"R","version":"V","clear":["parent","parent"]}"#, #"{"id":"R","version":"V","set":{"parent":"P"},"clear":["parent"]}"#] {
            #expect(throws: Failure.self) { try FacadeOperations.prepare("edit", arguments: arguments(json)) }
        }
        #expect(throws: Failure.self) { try FacadeOperations.prepare("lists_add", arguments: arguments(#"{"name":"N","fields":{"name":"N"}}"#)) }
    }
    @Test func sparseSmartListInputsKeepOmissionsAndRejectUnsafeChanges() throws {
        let rename = try FacadeOperations.prepare("smart_lists_edit", arguments: arguments(#"{"id":"S","set":{"name":"Renamed"}}"#))
        guard case .operation(.smartList(.update(let id, let patch, let clear))) = rename else { throw invalid("Expected smart edit") }
        #expect(id == "S"); #expect(patch.name == "Renamed"); #expect(clear.isEmpty)
        #expect(patch.match == nil); #expect(patch.filters == nil); #expect(patch.color == nil)
        #expect(try FacadeOperations.prepare("smart_lists_edit", arguments: arguments(#"{"id":"S","clear":["color","icon"]}"#)) == .operation(.smartList(.update("S", SmartListPatch(), clear: [.color, .icon]))))
        #expect(throws: Failure.self) { try FacadeOperations.prepare("smart_lists_edit", arguments: arguments(#"{"id":"S","set":{"color":"red"},"clear":["color"]}"#)) }
        #expect(throws: Failure.self) { try FacadeOperations.prepare("smart_lists_edit", arguments: arguments(#"{"id":"S","clear":["icon","icon"]}"#)) }
        #expect(throws: Failure.self) { try FacadeOperations.prepare("smart_lists_edit", arguments: arguments(#"{"id":"S","set":{"filters":[]}}"#)) }
        #expect(throws: Failure.self) { try FacadeOperations.prepare("smart_lists_add", arguments: arguments(#"{"name":"N","fields":{"filters":[{"kind":"flagged","value":true},{"kind":"flagged","value":false}]}}"#)) }
    }
    @Test func schemaRejectsUnknownNullInternalEnumsAndInvalidFields() throws {
        let samples: [(String, String)] = [
            ("setup", "{}"), ("show", #"{"id":"R","setup":true}"#), ("show", #"{"id":null}"#),
            ("edit", #"{"id":"R","version":"V","set":{"notes":null}}"#),
            ("edit", #"{"id":"R","version":"V","set":{"due":{"date":{"_0":{"year":2030,"month":1,"day":1}}}}}"#),
            ("edit", #"{"id":"R","version":"V","set":{"due":{"kind":"date","value":{"year":2030,"month":1,"day":1,"unknown":2}}}}"#),
            ("edit", #"{"id":"R","version":"V","set":{"notes":"x"},"clear":["notes"]}"#),
            ("lists_edit", #"{"id":"L","set":{}}"#), ("lists_delete", #"{"id":"L","confirmed":false}"#),
            ("lists_edit", #"{"id":"L","set":{"color":"red"},"clear":["color"]}"#),
            ("lists_edit", #"{"id":"L","clear":["icon","icon"]}"#), ("lists_edit", #"{"id":"L","clear":["name"]}"#),
            ("lists_edit", #"{"id":"L","set":{"color":null}}"#),
            ("smart_lists_edit", #"{"id":"S","set":{}}"#),
            ("smart_lists_edit", #"{"id":"S","set":{"color":null}}"#),
            ("smart_lists_edit", #"{"id":"S","set":{"id":"S"}}"#),
            ("smart_lists_add", #"{"name":"N","fields":{"name":"N","filters":[{"kind":"flagged","value":true}]}}"#),
            ("smart_lists_add", #"{"name":"N","fields":{"id":"S","filters":[{"kind":"flagged","value":true}]}}"#),
            ("smart_lists_add", #"{"name":"N","fields":{}}"#),
            ("smart_lists_add", #"{"name":"N","fields":{"filters":[{"kind":"unknown","key":"x","payload":"AQ=="}]}}"#),
            ("find", #"{"query":{}}"#), ("find", #"{"scope":"title"}"#), ("find", #"{"limit":1.5}"#), ("find", #"{"limit":0}"#),
            ("find", #"{"offset":-1}"#), ("find", #"{"text":"   "}"#),
            ("find", #"{"matching":"exact"}"#), ("find", #"{"matching":"bad","text":"x"}"#),
            ("find", #"{"smartList":"S","flagged":false}"#),
            ("find", #"{"smartList":"S","completed":true}"#),
            ("smart_lists_add", #"{"name":"N","fields":{"filters":[{"kind":"time","fromHour":8,"fromMinute":0,"toHour":17,"toMinute":0}]}}"#),
            ("smart_lists_add", #"{"name":"N","fields":{"filters":[{"kind":"date","value":{"kind":"overdue"}}]}}"#),
            ("smart_lists_add", #"{"name":"N","fields":{"filters":[{"kind":"location","value":"arriving"}]}}"#),
            ("smart_lists_add", #"{"name":"N","fields":{"filters":[{"kind":"priorities","value":["none"]}]}}"#),
            ("smart_lists_add", #"{"name":"N","fields":{"filters":[{"kind":"date","value":{"kind":"relative","past":0,"future":1,"unit":"minutes"}}]}}"#),
            ("find", #"{"section":"S"}"#), ("find", #"{"tags":[""]}"#),
            ("find", #"{"text":"fish","scope":"title"}"#),
            ("find", #"{"tagMatch":"any"}"#), ("find", #"{"tagMatch":"bad","tags":["x"]}"#),
            ("find", #"{"smartList":"S","excludeTags":["x"]}"#),
            ("find", #"{"assigneeID":"A"}"#), ("find", #"{"dueBefore":{}}"#), ("image", #"{"id":"R"}"#)
        ]
        for (name, text) in samples {
            do { _ = try FacadeOperations.prepare(name, arguments: arguments(text)); Issue.record("Expected invalid input") }
            catch let failure as Failure { #expect(failure.code == .invalidInput) }
        }
    }
    @Test func outputCodecRoundtripsFieldsWithoutLeakingCoreEnumsAndKeepsVersion() throws {
        var fields = ReminderFields(title: "T", listID: "L", due: .date(CalendarDate(2030, 2, 3)),
            start: .localDateTime(CalendarDate(2030, 2, 2), hour: 9, minute: 30, second: 0),
            recurrence: Recurrence(frequency: .monthly, end: .until(CalendarDate(2031, 1, 1))),
            location: .gettingInCar, position: .before("A"))
        fields.earlyAlerts = [EarlyAlert(before: 1, unit: .days)]
        let item = Reminder(id: "R", fields: fields, creationDate: Date(timeIntervalSince1970: 0),
            lastModifiedDate: Date(timeIntervalSince1970: 60), completionDate: Date(timeIntervalSince1970: 120))
        let output = try Presentation.output(.operation(ExecutionResult(status: .ok, result: .reminders([item]))))
        let encoded = String(decoding: try output.json(), as: UTF8.self)
        #expect(!encoded.contains("_0")); #expect(encoded.contains(#""kind":"localDateTime""#))
        guard case .object(let root) = output.result, case .array(let rows) = root["reminders"], case .object(let row) = rows[0] else { throw invalid("Expected reminder output") }
        #expect(row["version"] == .string(try item.version()))
        #expect(row["creationDate"] == .string("1970-01-01T00:00:00Z"))
        #expect(row["lastModifiedDate"] == .string("1970-01-01T00:01:00Z"))
        #expect(row["completionDate"] == .string("1970-01-01T00:02:00Z"))
        #expect(try Reminder(id: "R", fields: fields).version() == item.version())
        #expect(throws: Failure.self) { try FacadeOperations.prepare("edit", arguments: ["id": .string("R"), "version": .string("V"), "set": .object(["creationDate": row["creationDate"]!])]) }
        guard case .object(let outputFields) = row["fields"] else { throw invalid("Expected fields") }
        #expect(outputFields["listID"] == .string("L"))
        #expect(outputFields["position"] == .object(["kind": .string("before"), "value": .string("A")]))
        let smart = SmartList(id: "S", name: "N", filters: [.date(.relative(past: 0, future: 7, unit: .days)), .unknown(key: "native", payload: Data([1]))])
        let catalog = Catalog(lists: [ReminderList(id: "L", fields: ListFields(name: "N", position: .after("B")))],
            sections: [Section(id: "A", name: "N", listID: "L", position: .before("B"))], smartLists: [smart],
            templates: [NamedEntity(id: "T", name: "Template", color: "light-blue", icon: "star")])
        for scope in CatalogScope.allCases {
            let result = try Presentation.output(.operation(ExecutionResult(status: .ok, result: .catalog(catalog, scope: scope))))
            let text = String(decoding: try result.json(), as: UTF8.self)
            let body = try JSONValue.properties(try #require(result.result))
            #expect(Set(body.keys) == ["kind", scope.rawValue]); #expect(body["kind"] == .string(scope.rawValue))
            #expect(!text.contains("_0"))
            if scope == .all || scope == .smartLists { #expect(text.contains(#""kind":"unknown""#)); #expect(text.contains("AQ==")) }
            if scope == .all || scope == .templates { #expect(text.contains(#""color":"light-blue""#)); #expect(text.contains(#""icon":"star""#)) }
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
