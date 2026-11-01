import Foundation
import Darwin
import Testing
@testable import ReminderCore

private final class MemoryBackend: ReminderBackend {
    var items: [String: Reminder] = [:]
    var deletedItems: [String: Reminder] = [:]
    var data = Catalog(lists: [ReminderList(id: "L1", fields: ListFields(name: "Inbox"), isDefault: true),
                               ReminderList(id: "L2", fields: ListFields(name: "Work"))],
                       groups: [NamedEntity(id: "G1", name: "Group")],
                       sections: [Section(id: "S1", name: "First", listID: "L1"), Section(id: "S2", name: "Second", listID: "L1")],
                       tags: [Tag(name: "work")], smartLists: [SmartList(id: "SM1", name: "Smart")],
                       templates: [NamedEntity(id: "T1", name: "Template")])
    var unsupported = false
    var readError: Failure?
    var mutationError: Failure?
    var lookup: ((String) throws -> Void)?
    var beforeDelete: (() throws -> Void)?
    var beforeMutation: (() -> Void)?
    var recoveryLookup: ((String) throws -> Void)?
    var listReceiptIDs: [String]?
    var mutationCalls = 0
    var deleteCalls: [[String]] = []
    var actions: [Command] = []
    var patches: [ReminderPatch] = []
    var lookupCount = 0
    var hideRestoredChild = false
    var detachRestoredChild = false
    var restoreAuxiliaryIDs: [String] = []
    var restoreParentIDs: [String?] = []
    func checkSupport(for command: Command) throws {
        if unsupported { throw Failure(.unsupported, "Missing native selector") }
    }
    var catalogProjections: [Bool] = []
    func catalog(includeTags: Bool) throws -> Catalog {
        catalogProjections.append(includeTags)
        if let readError { throw readError }
        var result = data
        if !includeTags { result.tags = [] }
        return result
    }
    var lastQuery: ReminderQuery?
    var enumerationError: Failure?
    var enumerationLists: [String?] = []
    var titleQueries: [String] = []
    var titleCandidates: [Reminder]?
    func find(_ query: ReminderQuery) throws -> [Reminder] {
        if let readError { throw readError }
        lastQuery = query
        return items.values.sorted { $0.id < $1.id }
    }
    func reminders(listID: String?) throws -> [Reminder] {
        enumerationLists.append(listID)
        if let error = enumerationError ?? readError { throw error }
        return items.values.filter { listID == nil || $0.fields.listID == listID }.sorted { $0.id < $1.id }
    }
    func reminders(matchingTitle: String) throws -> [Reminder] {
        titleQueries.append(matchingTitle)
        if let readError { throw readError }
        return titleCandidates ?? items.values.filter { $0.fields.title == matchingTitle }.sorted { $0.id < $1.id }
    }
    func reminder(id: String) throws -> Reminder? {
        lookupCount += 1; try lookup?(id)
        if let readError { throw readError }
        return items.values.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }
    func restorableState(id: String) throws -> RestorableState {
        try recoveryLookup?(id)
        if let readError { throw readError }
        if deletedItems[id] != nil { return .restorable }
        return items[id] == nil ? .absent : .active
    }
    func image(reminderID: String, imageID: String) throws -> ImageInput {
        ImageInput(fileName: "x.png", contentType: "image/png", bytes: Data([1, 2]))
    }
    func begin() throws {
        beforeMutation?(); mutationCalls += 1
        if let mutationError { throw mutationError }
    }
    func createReminder(_ draft: ReminderDraft) throws -> MutationResult {
        try begin(); let item = Reminder(id: "created", fields: draft.fields); items[item.id] = item
        return MutationResult(affectedIDs: [item.id], reminders: [item])
    }
    func updateReminder(id: String, patch: ReminderPatch) throws -> MutationResult {
        try begin(); patches.append(patch); items[id]!.fields = try patch.applying(to: items[id]!.fields)
        items[id]!.images.removeAll { patch.removeImageIDs.contains($0.id) }
        return MutationResult(affectedIDs: [id], reminders: [items[id]!])
    }
    func deleteReminders(ids: [String]) throws -> MutationResult {
        deleteCalls.append(ids); try beforeDelete?(); try begin()
        for id in ids { deletedItems[id] = items.removeValue(forKey: id) }
        return MutationResult(affectedIDs: ids)
    }
    func restoreReminder(id: String, listID: String, knownChildIDs: [String], parentID: String?) throws -> MutationResult {
        try begin(); restoreParentIDs.append(parentID)
        var seen: Set<String> = [id]
        let children = (deletedItems[id]?.childIDs ?? []) + knownChildIDs
        let ids = [id] + children.filter { seen.insert($0).inserted }
        for id in ids {
            if hideRestoredChild && id != ids[0] { continue }
            guard var item = deletedItems.removeValue(forKey: id) else { continue }
            item.fields.listID = listID
            if detachRestoredChild && id != ids[0] { item.fields.parentID = nil }
            if id == ids[0], let parentID { item.fields.parentID = parentID }
            items[id] = item
            if let parent = item.fields.parentID, items[parent] != nil, !items[parent]!.childIDs.contains(id) {
                items[parent]!.childIDs.append(id)
            }
        }
        return MutationResult(affectedIDs: ids + restoreAuxiliaryIDs)
    }
    func list(_ action: ListAction) throws -> MutationResult {
        try begin(); actions.append(.list(action))
        if case .delete(let id, _) = action { return MutationResult(affectedIDs: listReceiptIDs ?? [id]) }
        return MutationResult(affectedIDs: ["list"])
    }
    func group(_ action: GroupAction) throws -> MutationResult { try begin(); actions.append(.group(action)); return MutationResult(affectedIDs: ["group"]) }
    func section(_ action: SectionAction) throws -> MutationResult { try begin(); actions.append(.section(action)); return MutationResult(affectedIDs: ["section"]) }
    func tag(_ action: TagAction) throws -> MutationResult { try begin(); actions.append(.tag(action)); return MutationResult(affectedIDs: ["tag"]) }
    func smartList(_ action: SmartListAction) throws -> MutationResult { try begin(); actions.append(.smartList(action)); return MutationResult(affectedIDs: ["smart"]) }
    func template(_ action: TemplateAction) throws -> MutationResult { try begin(); actions.append(.template(action)); return MutationResult(affectedIDs: ["template"]) }
}

private final class ReconciliationInterleave: @unchecked Sendable {
    let url: URL
    let done = DispatchSemaphore(value: 0)
    var error: Error?
    init(url: URL) { self.url = url }
    func update() {
        do {
            try DeletionJournal(url: url).transaction { entries in
                entries[0].title = "Changed during lookup"
                entries[1].state = .pending
                entries.append(DeletionEntry(id: "new", title: "New", listID: "L1", parentID: nil, time: Date(), state: .pending))
            }
        } catch { self.error = error }
        done.signal()
    }
}

struct OperationsTests {
    private func fixture(_ body: (MemoryBackend, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CoreTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = MemoryBackend()
        backend.items["R1"] = Reminder(id: "R1", fields: ReminderFields(title: "Task", listID: "L1"))
        try body(backend, directory.appendingPathComponent("deleted.json"))
    }
    @Test func testCatalogProjectionSeparatesResolutionFromTagCounts() throws {
        try fixture { backend, url in
            let engine = Operations(backend: backend, journalURL: url)
            var patch = ReminderPatch(); patch.title = .set("Edited")
            let version = try backend.items["R1"]!.version()
            #expect(engine.execute(.update(id: "R1", version: version, patch: patch)).status == .ok)
            #expect(backend.catalogProjections == [false])
            backend.catalogProjections = []
            #expect(engine.execute(.catalog(includeTags: false)).status == .ok)
            #expect(engine.execute(.catalog(includeTags: true)).status == .ok)
            #expect(engine.execute(.tag(.rename("work", name: "job"))).status == .ok)
            #expect(backend.catalogProjections == [false, true])
        }
    }
    @Test func tagMutationPassesNativeAliasWithoutCatalogRead() throws {
        try fixture { backend, url in
            let engine = Operations(backend: backend, journalURL: url)
            let rename = TagAction.rename("WoRk", name: "JOB")
            let delete = TagAction.delete("wOrK", confirmed: true)
            backend.unsupported = true
            let refused = engine.execute(.tag(rename))
            #expect(refused.status == .failed); #expect(refused.error?.code == .unsupported)
            #expect(backend.actions.isEmpty); #expect(backend.mutationCalls == 0)
            backend.unsupported = false
            #expect(engine.execute(.tag(rename)).status == .ok)
            #expect(engine.execute(.tag(delete)).status == .ok)
            #expect(backend.actions == [.tag(rename), .tag(delete)])
            #expect(backend.catalogProjections.isEmpty)
        }
    }
    @Test func restoredChildReceiptAllowsOnlyItsActualActiveParentAndKeepsParentJournal() throws {
        try fixture { backend, url in
            let child = Reminder(id: "CHILD", fields: ReminderFields(title: "Child", listID: "L1", parentID: "R1"))
            backend.deletedItems[child.id] = child
            backend.restoreAuxiliaryIDs = ["R1"]
            let journal = DeletionJournal(url: url)
            try journal.transaction { entries in
                entries = [DeletionEntry(id: child.id, title: "Child", listID: "L1", parentID: "R1", time: Date(), state: .confirmed),
                    DeletionEntry(id: "R1", title: "Task", listID: "L1", parentID: nil, time: Date(), state: .pending)]
            }
            let result = Operations(backend: backend, journalURL: url).execute(.restore(id: "CHILD", list: nil))
            #expect(result.status == .ok)
            guard case .mutation(let receipt) = result.result else { Issue.record("Expected restore receipt"); return }
            #expect(Set(receipt.affectedIDs) == ["CHILD", "R1"])
            #expect(try journal.read().map(\.id) == ["R1"])
        }
        try fixture { backend, url in
            let child = Reminder(id: "CHILD", fields: ReminderFields(title: "Child", listID: "L1", parentID: "R1"))
            backend.deletedItems[child.id] = child
            backend.items["OTHER"] = Reminder(id: "OTHER", fields: ReminderFields(title: "Unrelated", listID: "L1"))
            backend.restoreAuxiliaryIDs = ["OTHER"]
            let journal = DeletionJournal(url: url)
            try journal.transaction { entries in entries = [DeletionEntry(id: child.id, title: "Child", listID: "L1", parentID: "R1", time: Date(), state: .confirmed)] }
            let result = Operations(backend: backend, journalURL: url).execute(.restore(id: "CHILD", list: nil))
            #expect(result.status == .unknown)
            #expect(try journal.read().map(\.id) == ["CHILD"])
        }
    }
    @Test func journaledUnrelatedRestoreReceiptNeverBecomesSubtreeOrCompactedEvidence() throws {
        try fixture { backend, url in
            let child = Reminder(id: "CHILD", fields: ReminderFields(title: "Child", listID: "L1", parentID: "R1"))
            backend.deletedItems[child.id] = child
            backend.items["OTHER"] = Reminder(id: "OTHER", fields: ReminderFields(title: "Unrelated", listID: "L1"))
            backend.restoreAuxiliaryIDs = ["R1", "OTHER"]
            let journal = DeletionJournal(url: url)
            let saved = [
                DeletionEntry(id: child.id, title: "Child", listID: "L1", parentID: "R1", time: Date(), state: .confirmed),
                DeletionEntry(id: "R1", title: "Task", listID: "L1", parentID: nil, time: Date(), state: .pending),
                DeletionEntry(id: "OTHER", title: "Unrelated", listID: "L1", parentID: nil, time: Date(), state: .pending)
            ]
            try journal.transaction { $0 = saved }
            let result = Operations(backend: backend, journalURL: url).execute(.restore(id: "CHILD", list: nil))
            #expect(result.status == .unknown)
            #expect(result.error?.code == .outcomeUnknown)
            #expect(Set(result.error?.affectedIDs ?? []) == ["CHILD", "R1", "OTHER"])
            #expect(try journal.read() == saved)
        }
    }
    @Test func findPassesNativeQueryAndReturnsBackendResults() throws {
        try fixture { backend, url in
            var query = ReminderQuery(); query.text = "does not match"; query.matching = .prefix
            query.list = "Inbox"; query.flagged = false; query.hasDueDate = false; query.offset = 2; query.limit = 3
            let result = Operations(backend: backend, journalURL: url).execute(.find(query))
            query.list = "L1"
            #expect(backend.lastQuery == query)
            #expect(result.result == .reminders([backend.items["R1"]!]))
        }
    }
    @Test func queryValidationRejectsInvalidCombinationsBeforeBackend() throws {
        try fixture { backend, url in
            let engine = Operations(backend: backend, journalURL: url)
            var invalid: [ReminderQuery] = []
            var q = ReminderQuery(); q.text = " \n"; invalid.append(q)
            q = ReminderQuery(); q.matching = .word; invalid.append(q)
            q = ReminderQuery(); q.offset = -1; invalid.append(q)
            q = ReminderQuery(); q.limit = 0; invalid.append(q)
            q = ReminderQuery(); q.smartList = "Smart"; q.hasDueDate = false; invalid.append(q)
            q = ReminderQuery(); q.smartList = "Smart"; q.list = "Inbox"; invalid.append(q)
            q = ReminderQuery(); q.smartList = "Smart"; q.completed = true; invalid.append(q)
            for query in invalid { #expect(engine.execute(.find(query)).error?.code == .invalidInput) }
            #expect(backend.lastQuery == nil); #expect(backend.catalogProjections.isEmpty)
            q = ReminderQuery(); q.smartList = "Smart"; q.includeCompleted = true; q.offset = 2
            #expect(engine.execute(.find(q)).status == .ok)
            #expect(backend.lastQuery?.smartList == "SM1")
        }
    }
    @Test func titleLookupAndExhaustiveReadsProtectDeletion() throws {
        try fixture { backend, url in
            let engine = Operations(backend: backend, journalURL: url)
            backend.items["R2"] = Reminder(id: "R2", fields: ReminderFields(title: "Task", listID: "L2", completed: true))
            #expect(engine.execute(.show("Task")).error?.code == .ambiguous)
            #expect(backend.titleQueries == ["Task"])
            #expect(backend.enumerationLists.isEmpty)
            backend.enumerationError = Failure(.backend, "enumeration failed")
            #expect(engine.execute(.list(.delete("Inbox", confirmed: true))).error?.code == .backend)
            #expect(backend.enumerationLists.last! == "L1")
            #expect(backend.mutationCalls == 0)
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }
    @Test func titleResolutionUsesNativeCandidatesWithoutFiltering() throws {
        try fixture { backend, url in
            let engine = Operations(backend: backend, journalURL: url)
            let candidate = Reminder(id: "R2", fields: ReminderFields(title: "Different native match", listID: "L2", completed: true))
            backend.titleCandidates = [candidate]
            #expect(engine.execute(.show("requested title")).result == .reminders([candidate]))
            #expect(backend.titleQueries == ["requested title"])
            backend.titleCandidates = [candidate, backend.items["R1"]!]
            #expect(engine.execute(.show("requested title")).error?.code == .ambiguous)
            backend.titleCandidates = []
            #expect(engine.execute(.show("requested title")).error?.code == .notFound)
            #expect(backend.enumerationLists.isEmpty)
        }
    }
    @Test func testNamesAreExactAmbiguityFailsAndIDsIgnoreCase() throws {
        try fixture { backend, url in
            let engine = Operations(backend: backend, journalURL: url)
            #expect(engine.execute(.show("r1")).status == .ok)
            #expect(backend.lookupCount == 1) // ID did not demand an account scan
            #expect(engine.execute(.show("task")).error?.code == .notFound)
            backend.items["R2"] = Reminder(id: "R2", fields: backend.items["R1"]!.fields)
            #expect(engine.execute(.show("Task")).error?.code == .ambiguous)
            backend.data.lists.append(ReminderList(id: "L3", fields: ListFields(name: "Inbox")))
            #expect(engine.execute(.create(ReminderDraft(fields: ReminderFields(title: "New", listID: "Inbox")))).error?.code == .ambiguous)
            #expect(backend.mutationCalls == 0)
        }
    }
    @Test func creationInheritsParentOrUsesUniqueDefaultList() throws {
        try fixture { backend, url in
            let engine = Operations(backend: backend, journalURL: url)
            var fields = ReminderFields(title: "New", listID: "")
            #expect(engine.execute(.create(ReminderDraft(fields: fields))).status == .ok)
            #expect(backend.items["created"]?.fields.listID == "L1")
            backend.items["R1"]!.fields.listID = "L2"; fields.parentID = "R1"
            backend.data.lists[0].isDefault = false
            #expect(engine.execute(.create(ReminderDraft(fields: fields))).status == .ok)
            #expect(backend.items["created"]?.fields.listID == "L2")
            fields.parentID = nil
            #expect(engine.execute(.create(ReminderDraft(fields: fields))).error?.code == .notFound)
            backend.data.lists[0].isDefault = true; backend.data.lists[1].isDefault = true
            #expect(engine.execute(.create(ReminderDraft(fields: fields))).error?.code == .ambiguous)
            #expect(backend.mutationCalls == 2)
        }
    }
    @Test func testStaleVersionAndLastMomentRecheckRejectWithoutMutation() throws {
        try fixture { backend, url in
            let engine = Operations(backend: backend, journalURL: url)
            var patch = ReminderPatch(); patch.notes = .set("changed")
            #expect(engine.execute(.update(id: "R1", version: "old", patch: patch)).error?.code == .conflict)
            let version = try backend.items["R1"]!.version()
            backend.lookup = { id in
                if backend.lookupCount == 3 { backend.items[id]?.fields.earlyAlerts = [EarlyAlert(before: 5, unit: .minutes)] }
            }
            #expect(engine.execute(.update(id: "R1", version: version, patch: patch)).error?.code == .conflict)
            #expect(backend.mutationCalls == 0)
        }
    }
    @Test func smartFilterValidationRejectsImpossibleInputsBeforeBackend() throws {
        try fixture { backend, url in
            backend.unsupported = true
            let filters: [SmartFilter] = [.priorities([.none]), .date(.relative(past: 0, future: 1, unit: .minutes)),
                .date(.relative(past: 1, future: 1, unit: .days)), .date(.relative(past: 0, future: 0, unit: .days)),
                .date(.relative(past: -1, future: 1, unit: .hours))]
            let engine = Operations(backend: backend, journalURL: url)
            for filter in filters {
                #expect(engine.execute(.smartList(.create(SmartList(id: "", name: "Invalid", filters: [filter])))).error?.code == .invalidInput)
            }
            #expect(backend.mutationCalls == 0); #expect(backend.catalogProjections.isEmpty)
        }
    }
    @Test func testVersionCoversEveryEditableFieldAndImageMetadata() throws {
        let original = Reminder(id: "R", fields: ReminderFields(title: "T", listID: "L"))
        let version = try original.version()
        let changes: [(inout Reminder) -> Void] = [
            { $0.fields.title = "N" }, { $0.fields.listID = "M" }, { $0.fields.notes = "n" },
            { $0.fields.due = .date(CalendarDate(2026, 1, 1)) }, { $0.fields.start = .date(CalendarDate(2025, 1, 1)) },
            { $0.fields.recurrence = Recurrence(frequency: .daily) },
            { $0.fields.earlyAlerts = [EarlyAlert(before: 1, unit: .hours)] },
            { $0.fields.location = .gettingInCar }, { $0.fields.contact = ContactAlert(phones: ["1"]) },
            { $0.fields.url = "https://example.test" }, { $0.fields.priority = .high }, { $0.fields.flagged = true },
            { $0.fields.urgent = true }, { $0.fields.completed = true }, { $0.fields.tags = ["tag"] },
            { $0.fields.parentID = "P" }, { $0.fields.sectionID = "S" }, { $0.fields.position = .after("A") },
            { $0.fields.assigneeID = "M" }, { $0.childIDs = ["C"] },
            { $0.images = [ImageAttachment(id: "I", fileName: "x", contentType: "image/png", byteCount: 2)] }
        ]
        for change in changes { var item = original; change(&item); #expect(try item.version() != version) }
        let bytes = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(Reminder.self, from: bytes).version() == version)
        #expect(version.count == 64)
    }
    @Test func testPatchAbsentSetClearAndCompletion() throws {
        try fixture { backend, url in
            backend.items["R1"]!.fields.notes = "old"
            let engine = Operations(backend: backend, journalURL: url)
            var patch = ReminderPatch(); patch.notes = .clear; patch.flagged = .set(true)
            let result = engine.execute(.update(id: "R1", version: try backend.items["R1"]!.version(), patch: patch))
            #expect(result.status == .ok); #expect(backend.items["R1"]!.fields.notes == nil)
            #expect(backend.items["R1"]!.fields.title == "Task"); #expect(backend.items["R1"]!.fields.flagged)
            #expect(engine.execute(.complete(id: "R1", version: try backend.items["R1"]!.version(), completed: true)).status == .ok)
            #expect(backend.items["R1"]!.fields.completed)
            patch.title = .clear
            #expect(engine.execute(.update(id: "R1", version: try backend.items["R1"]!.version(), patch: patch)).error?.code == .invalidInput)
        }
    }
    @Test func testParentMoveSectionAndNeighborRestrictions() throws {
        try fixture { (backend: MemoryBackend, url: URL) throws in
            let engine = Operations(backend: backend, journalURL: url)
            func update(_ change: (inout ReminderPatch) -> Void) throws -> ErrorCode? {
                var patch = ReminderPatch(); change(&patch)
                return engine.execute(.update(id: "R1", version: try backend.items["R1"]!.version(), patch: patch)).error?.code
            }
            #expect(try update { $0.parentID = .set("R1") } == .invalidInput)
            backend.items["P"] = Reminder(id: "P", fields: ReminderFields(title: "P", listID: "L2"))
            #expect(try update { $0.parentID = .set("P") } == .invalidInput)
            backend.items["P"]!.fields.listID = "L1"; backend.items["P"]!.fields.parentID = "TOP"
            #expect(try update { $0.parentID = .set("P") } == .invalidInput)
            backend.items["R1"]!.childIDs = ["C"]
            #expect(try update { $0.listID = .set("L2") } == .invalidInput)
            backend.items["R1"]!.childIDs = []
            #expect(try update { $0.sectionID = .set("not-real") } == .notFound)
            backend.items["P"]!.fields.parentID = nil; backend.items["P"]!.fields.sectionID = "S1"
            #expect(try update { $0.position = .set(.after("P")) } == .invalidInput)
            #expect(try update { $0.sectionID = .set("First"); $0.position = .set(.after("P")) } == nil)
        }
    }
    @Test func testRecurrenceCivilDateRichFieldsAndBytesRoundTrip() throws {
        try fixture { (backend: MemoryBackend, url: URL) throws in
            backend.data.lists[0].members = [Member(id: "M1", name: "Joined", isCurrentUser: true)]
            let f = ReminderFields(title: "Recurring", listID: "Inbox", due: .localDateTime(CalendarDate(2026, 11, 1), hour: 9, minute: 30, second: 0),
                start: .date(CalendarDate(2026, 10, 31)), recurrence: Recurrence(frequency: .monthly, weekdays: [RecurrenceDay(.monday, ordinal: -1)], end: .count(5)),
                earlyAlerts: [EarlyAlert(before: 15, unit: .minutes)], location: .gettingOutOfCar,
                contact: ContactAlert(emails: ["person@example.test"]), urgent: true, assigneeID: "me")
            let command = Command.create(ReminderDraft(fields: f, images: [ImageInput(fileName: "x.png", contentType: "image/png", bytes: Data([1, 2, 3]))]))
            #expect(try JSONDecoder().decode(Command.self, from: JSONEncoder().encode(command)) == command)
            #expect(Operations(backend: backend, journalURL: url).execute(command).status == .ok)
            #expect(backend.items["created"]!.fields.assigneeID == "M1")
            #expect(backend.items["created"]!.fields.due == f.due)
            #expect(throws: (any Error).self) { try Validation.date(CalendarDate(2026, 2, 29)) }
            #expect(throws: Never.self) { try Validation.date(CalendarDate(2024, 2, 29)) }
            var invalid = f; invalid.recurrence!.interval = 0
            #expect(throws: (any Error).self) { try Validation.fields(invalid) }
            invalid = f; invalid.recurrence!.weekdays[0].ordinal = 0
            #expect(throws: (any Error).self) { try Validation.fields(invalid) }
            invalid = f; invalid.due = .date(CalendarDate(2026, 11, 1))
            #expect(throws: (any Error).self) { try Validation.fields(invalid) } // urgent cannot be all-day
            invalid = f; invalid.due = nil
            #expect(throws: (any Error).self) { try Validation.fields(invalid) }
        }
    }
    @Test func testUnsupportedIsNotEmptyAndReadFailuresPropagateExactly() throws {
        try fixture { backend, url in
            let engine = Operations(backend: backend, journalURL: url)
            backend.unsupported = true
            #expect(engine.execute(.find(ReminderQuery())).error?.code == .unsupported)
            backend.unsupported = false; backend.items = [:]
            #expect(engine.execute(.find(ReminderQuery())).result == .reminders([]))
            let failure = Failure(.permission, "denied", affectedIDs: ["original-evidence"])
            backend.readError = failure
            #expect(engine.execute(.catalog(includeTags: true)).error == failure)
            #expect(engine.execute(.show("R1")).error == failure)
        }
    }
    @Test func testCallbackImmediatelyBeforeMutationAndUncertaintyIsNotRetried() throws {
        try fixture { backend, url in
            var callbackCalled = false
            backend.beforeMutation = { #expect(callbackCalled) }
            let engine = Operations(backend: backend, journalURL: url, onMutation: { callbackCalled = true })
            backend.mutationError = Failure(.backend, "Save failed after start", affectedIDs: ["R1"])
            let result = engine.execute(.complete(id: "R1", version: try backend.items["R1"]!.version(), completed: true))
            #expect(result.status == .unknown); #expect(result.error?.underlyingCode == .backend)
            #expect(result.error?.affectedIDs == ["R1"]); #expect(backend.mutationCalls == 1)
            let veto = Operations(backend: backend, journalURL: url, onMutation: { throw Failure(.io, "Frame write failed") })
            #expect(veto.execute(.complete(id: "R1", version: try backend.items["R1"]!.version(), completed: true)).error?.code == .io)
            #expect(backend.mutationCalls == 1)
        }
    }
    @Test func testJournalFailurePreventsDeleteAndPendingPrecedesOneBulkSave() throws {
        try fixture { backend, url in
            try Data("malformed".utf8).write(to: url)
            let engine = Operations(backend: backend, journalURL: url)
            let version = try backend.items["R1"]!.version()
            #expect(engine.execute(.delete(id: "R1", version: version)).error?.code == .io)
            #expect(backend.deleteCalls.isEmpty)
            try FileManager.default.removeItem(at: url)
            backend.items["R1"]!.childIDs = ["C"]
            backend.items["C"] = Reminder(id: "C", fields: ReminderFields(title: "Child", listID: "L1", parentID: "R1"))
            backend.beforeDelete = {
                let entries = try DeletionJournal(url: url).read()
                #expect(entries.map(\.id) == ["R1", "C"])
                #expect(entries.allSatisfy { $0.state == .pending })
                #expect(entries[1].parentID == "R1"); #expect(entries[0].listID == "L1")
            }
            #expect(engine.execute(.delete(id: "R1", version: try backend.items["R1"]!.version())).status == .ok)
            #expect(backend.deleteCalls == [["R1", "C"]])
            #expect(try DeletionJournal(url: url).read().allSatisfy { $0.state == .confirmed })
        }
    }
    @Test func testPendingIntentSurvivesUncertainDeleteAndReconciliationReadFailure() throws {
        try fixture { backend, url in
            backend.mutationError = Failure(.backend, "Interrupted")
            let engine = Operations(backend: backend, journalURL: url)
            #expect(engine.execute(.delete(id: "R1", version: try backend.items["R1"]!.version())).status == .unknown)
            let journal = DeletionJournal(url: url)
            #expect(try journal.read().map(\.state) == [.pending])
            let bytes = try Data(contentsOf: url)
            backend.readError = Failure(.backend, "Recovery lookup failed")
            #expect(engine.execute(.deleted).error?.code == .backend)
            #expect(try Data(contentsOf: url) == bytes)
            backend.readError = nil
            guard case .deleted(let deleted) = engine.execute(.deleted).result else {
                Issue.record("No deleted result"); return
            }
            #expect(deleted.scope == .toolOnly); #expect(deleted.entries.count == 1) // active pending retained
            backend.items = [:]
            #expect(engine.execute(.deleted).status == .ok)
            #expect(try journal.read().isEmpty) // authoritative absent permits reconciliation
        }
    }
    @Test func testRestoreOriginalListAndChildrenAndNoJournalWithoutTarget() throws {
        try fixture { (backend: MemoryBackend, url: URL) throws in
            backend.items["R1"]!.childIDs = ["C"]
            backend.items["C"] = Reminder(id: "C", fields: ReminderFields(title: "Child", listID: "L1", parentID: "R1"))
            let engine = Operations(backend: backend, journalURL: url)
            #expect(engine.execute(.delete(id: "R1", version: try backend.items["R1"]!.version())).status == .ok)
            let result = engine.execute(.restore(id: "r1", list: nil))
            #expect(result.status == .ok)
            guard case .mutation(let mutation) = result.result else {
                Issue.record("No restore result"); return
            }
            #expect(Set(mutation.reminders.map(\.id)) == ["R1", "C"])
            #expect(mutation.reminders.allSatisfy { $0.fields.listID == "L1" })
            #expect(try DeletionJournal(url: url).read().isEmpty)
            #expect(engine.execute(.restore(id: "other", list: nil)).error?.code == .invalidInput)
        }
    }
    @Test func restoreCompactionPreservesConcurrentChangesAndHandlesDuplicateSavedIDs() throws {
        try fixture { backend, url in
            let root = Reminder(id: "R1", fields: ReminderFields(title: "Root", listID: "L1"), childIDs: ["C"])
            let child = Reminder(id: "C", fields: ReminderFields(title: "Child", listID: "L1", parentID: "R1"))
            backend.items = [:]; backend.deletedItems = [root.id: root, child.id: child]
            let journal = DeletionJournal(url: url), time = Date(timeIntervalSince1970: 100)
            let savedRoot = DeletionEntry(id: "R1", title: "Root", listID: "L1", parentID: nil, time: time, state: .confirmed)
            let firstChild = DeletionEntry(id: "C", title: "Child", listID: "L1", parentID: "R1", time: time, state: .confirmed)
            let duplicate = DeletionEntry(id: "c", title: "Older duplicate", listID: "L1", parentID: "R1", time: time, state: .confirmed)
            let unrelated = DeletionEntry(id: "other", title: "Keep", listID: "L1", parentID: nil, time: time, state: .pending)
            try journal.transaction { $0 = [savedRoot, firstChild, duplicate, unrelated] }
            backend.beforeMutation = {
                try! journal.transaction { $0[2].title = "Changed during restore" }
            }
            let result = Operations(backend: backend, journalURL: url).execute(.restore(id: "R1", list: nil))
            #expect(result.status == .ok)
            guard case .mutation(let receipt) = result.result else { Issue.record("Expected restore receipt"); return }
            #expect(Set(receipt.affectedIDs) == ["R1", "C", "c"])
            var changed = duplicate; changed.title = "Changed during restore"
            #expect(try journal.read() == [changed, unrelated])
        }
    }
    @Test func testRestoreMissingChildAndVerificationReadFailureKeepJournalAndEvidence() throws {
        try fixture { backend, url in
            backend.items["R1"]!.childIDs = ["C"]
            backend.items["C"] = Reminder(id: "C", fields: ReminderFields(title: "C", listID: "L1", parentID: "R1"))
            let engine = Operations(backend: backend, journalURL: url)
            #expect(engine.execute(.delete(id: "R1", version: try backend.items["R1"]!.version())).status == .ok)
            let before = try Data(contentsOf: url)
            backend.hideRestoredChild = true
            let result = engine.execute(.restore(id: "R1", list: nil))
            #expect(result.status == .unknown)
            #expect(result.error?.underlyingCode == .notFound)
            #expect(Set(result.error?.affectedIDs ?? []) == ["C", "R1"])
            #expect(try Data(contentsOf: url) == before)
            // A read throwing after native success is also uncertainty, not a silently dropped result.
            backend.deletedItems["R1"] = backend.items.removeValue(forKey: "R1")
            backend.lookup = { _ in throw Failure(.permission, "verification denied") }
            #expect(engine.execute(.restore(id: "R1", list: "Work")).error?.underlyingCode == .permission)
            #expect(try Data(contentsOf: url) == before)
        }
    }
    @Test func testContainerFamiliesRouteTypedIDsAndRequireConfirmation() throws {
        try fixture { (backend: MemoryBackend, url: URL) throws in
            backend.items = [:]
            let engine = Operations(backend: backend, journalURL: url)
            let commands: [Command] = [
                .list(.create(ListFields(name: "New"))), .list(.update("Inbox", ListFields(name: "Renamed"))),
                .list(.clearCompleted("Inbox", confirmed: true)), .list(.delete("Work", confirmed: true)),
                .group(.create("G")), .group(.rename("Group", name: "G")), .group(.delete("Group", confirmed: true)),
                .section(.create(list: "Inbox", name: "S")), .section(.rename(list: "Inbox", section: "First", name: "N")),
                .section(.move(list: "Inbox", section: "First", position: .after("Second"))),
                .section(.delete(list: "Inbox", section: "First", confirmed: true)),
                .tag(.rename("work", name: "home")), .tag(.delete("work", confirmed: true)),
                .smartList(.create(SmartList(id: "", name: "New", filters: [.flagged(true)]))),
                .smartList(.update("Smart", SmartList(id: "SM1", name: "Renamed"))), .smartList(.delete("Smart", confirmed: true)),
                .template(.create(name: "Saved", list: "Inbox", includeCompleted: true)),
                .template(.use("Template", newListName: "From Template")), .template(.delete("Template", confirmed: true))
            ]
            for command in commands { #expect(engine.execute(command).status == .ok, "\(command)") }
            #expect(backend.actions.count == commands.count - 1) // empty clear-completed has no native save
            #expect(backend.actions.contains(.section(.move(list: "L1", section: "S1", position: .after("S2")))))
            #expect(backend.actions.contains(.template(.create(name: "Saved", list: "L1", includeCompleted: true))))
            let count = backend.mutationCalls
            for command: Command in [.list(.delete("Inbox", confirmed: false)), .group(.delete("Group", confirmed: false)),
                .section(.delete(list: "Inbox", section: "First", confirmed: false)), .tag(.delete("work", confirmed: false)),
                .smartList(.delete("Smart", confirmed: false)), .template(.delete("Template", confirmed: false))] {
                #expect(engine.execute(command).error?.code == .invalidInput)
            }
            #expect(backend.mutationCalls == count)
            let unknown = SmartFilter.unknown(key: "future", payload: Data([1, 2, 3]))
            #expect(try JSONDecoder().decode(SmartFilter.self, from: JSONEncoder().encode(unknown)) == unknown)
            #expect(engine.execute(.smartList(.create(SmartList(id: "", name: "Unknown", filters: [unknown])))).error?.code == .unsupported)
        }
    }
    @Test func restoringSavedChildPreflightsActualParentAndPreservesEvidenceOnRefusal() throws {
        for scenario in ["valid", "crossList", "missing", "nested"] {
            try fixture { backend, url in
                backend.items["R1"]!.fields.parentID = "P"
                if scenario != "missing" {
                    backend.items["P"] = Reminder(id: "P", fields: ReminderFields(title: "Parent", listID: "L1",
                        parentID: scenario == "nested" ? "TOP" : nil))
                }
                let engine = Operations(backend: backend, journalURL: url)
                #expect(engine.execute(.delete(id: "R1", version: try backend.items["R1"]!.version())).status == .ok)
                let before = try Data(contentsOf: url)
                var parentReads = 0
                backend.lookup = { if $0 == "P" { parentReads += 1 } }
                let result = engine.execute(.restore(id: "R1", list: scenario == "crossList" ? "Work" : nil))
                if scenario == "valid" {
                    #expect(result.status == .ok); #expect(backend.mutationCalls == 2)
                    #expect(backend.restoreParentIDs == ["P"])
                    #expect(parentReads >= 2) // preflight and after native restore
                    #expect(try DeletionJournal(url: url).read().isEmpty)
                } else {
                    #expect(result.status == .failed); #expect(backend.mutationCalls == 1)
                    #expect(result.error?.code == (scenario == "missing" ? .notFound : .invalidInput))
                    #expect(parentReads == 1); #expect(backend.deletedItems["R1"] != nil)
                    #expect(try Data(contentsOf: url) == before)
                }
            }
        }
    }
    @Test func restoredChildActualParentIsRecheckedBeforeJournalCompaction() throws {
        for scenario in ["missing", "crossList", "nested"] {
            try fixture { backend, url in
                backend.items["R1"]!.fields.parentID = "P"
                backend.items["P"] = Reminder(id: "P", fields: ReminderFields(title: "Parent", listID: "L1"))
                let engine = Operations(backend: backend, journalURL: url)
                #expect(engine.execute(.delete(id: "R1", version: try backend.items["R1"]!.version())).status == .ok)
                let before = try Data(contentsOf: url)
                backend.beforeMutation = {
                    if scenario == "missing" { backend.items.removeValue(forKey: "P") }
                    else if scenario == "crossList" { backend.items["P"]!.fields.listID = "L2" }
                    else { backend.items["P"]!.fields.parentID = "TOP" }
                }
                let result = engine.execute(.restore(id: "R1", list: nil))
                #expect(result.status == .unknown); #expect(backend.mutationCalls == 2)
                #expect(result.error?.underlyingCode == (scenario == "missing" ? .notFound : .invalidInput))
                #expect(backend.items["R1"]?.fields.parentID == "P")
                #expect(try Data(contentsOf: url) == before)
            }
        }
    }
    @Test func canonicalSetsAndSparsePatchesPreserveUntouchedNativeState() throws {
        var item = Reminder(id: "R", fields: ReminderFields(title: "T", listID: "L", tags: ["b", "a"]), childIDs: ["C2", "C1"])
        item.fields.contact = ContactAlert(phones: ["2", "1"], emails: ["b@x", "a@x"])
        item.fields.earlyAlerts = [EarlyAlert(before: 1, unit: .days), EarlyAlert(before: 5, unit: .minutes)]
        item.fields.recurrence = Recurrence(frequency: .yearly, weekdays: [RecurrenceDay(.monday), RecurrenceDay(.friday)], monthDays: [2, 1], months: [12, 1])
        let version = try item.version()
        item.childIDs.reverse(); item.fields.tags.reverse(); item.fields.contact!.phones.reverse()
        item.fields.contact!.emails.reverse(); item.fields.earlyAlerts.reverse(); item.fields.recurrence!.weekdays.reverse()
        item.fields.recurrence!.months.reverse(); item.fields.recurrence!.monthDays.reverse()
        #expect(try item.version() == version)
        try fixture { backend, url in
            let sparse = try JSONDecoder().decode(ReminderPatch.self, from: Data("{\"flagged\":{\"set\":{\"_0\":true}}}".utf8))
            #expect(sparse.notes == .absent); #expect(sparse.flagged == .set(true))
            #expect(throws: (any Error).self) { try JSONDecoder().decode(ReminderPatch.self, from: Data("{\"notes\":null}".utf8)) }
            let engine = Operations(backend: backend, journalURL: url)
            #expect(engine.execute(.update(id: "R1", version: try backend.items["R1"]!.version(), patch: sparse)).status == .ok)
            #expect(backend.patches == [sparse])
            #expect(backend.patches[0].recurrence == .absent); #expect(backend.patches[0].position == .absent)
            #expect(engine.execute(.update(id: "R1", version: try backend.items["R1"]!.version(), patch: sparse)).status == .ok)
            #expect(backend.patches.last?.flagged == .set(true)) // set-to-same remains explicit intent
        }
    }
    @Test func restoreParentVerificationFailurePreservesJournal() throws {
        try fixture { backend, url in
            backend.items["R1"]!.childIDs = ["C"]
            backend.items["C"] = Reminder(id: "C", fields: ReminderFields(title: "Child", listID: "L1", parentID: "R1"))
            let engine = Operations(backend: backend, journalURL: url)
            #expect(engine.execute(.delete(id: "R1", version: try backend.items["R1"]!.version())).status == .ok)
            let original = try Data(contentsOf: url); backend.detachRestoredChild = true
            let result = engine.execute(.restore(id: "R1", list: nil))
            #expect(result.status == .unknown); #expect(result.error?.underlyingCode == .conflict)
            #expect(try Data(contentsOf: url) == original)
        }
    }
    @Test(.enabled(if: getuid() != 0)) func journalConfirmationFailureAfterSaveIsUnknownWithReceipt() throws {
        try fixture { backend, url in
            let directory = url.deletingLastPathComponent()
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
            try DeletionJournal(url: url).transaction { $0 = [] }
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
            let engine = Operations(backend: backend, journalURL: url)
            #expect(engine.execute(.delete(id: "R1", version: try backend.items["R1"]!.version())).error?.code == .io)
            #expect(backend.deleteCalls.isEmpty)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            backend.beforeMutation = { try! FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path) }
            let result = engine.execute(.delete(id: "R1", version: try backend.items["R1"]!.version()))
            #expect(result.status == .unknown); #expect(result.error?.underlyingCode == .io)
            #expect(result.error?.affectedIDs == ["R1"]); #expect(backend.deletedItems["R1"] != nil)
            #expect(try DeletionJournal(url: url).read().map(\.state) == [.pending])
        }
    }
    @Test func callsAreSerializedWithinOneEngine() throws {
        try fixture { backend, url in
            var active = 0, maximum = 0
            backend.lookup = { _ in
                active += 1; maximum = max(maximum, active)
                Thread.sleep(forTimeInterval: 0.001); active -= 1
            }
            let engine = Operations(backend: backend, journalURL: url)
            DispatchQueue.concurrentPerform(iterations: 12) { _ in #expect(engine.execute(.show("R1")).status == .ok) }
            #expect(maximum == 1); #expect(backend.lookupCount == 12)
        }
    }
    @Test func clearCompletedUsesOnlyExactJournaledIDs() throws {
        try fixture { (backend: MemoryBackend, url: URL) throws in
            backend.items["R1"]!.fields.completed = true
            backend.beforeDelete = { () throws in
                backend.items["late"] = Reminder(id: "late", fields: ReminderFields(title: "Late completion", listID: "L1", completed: true))
                #expect(try DeletionJournal(url: url).read().map(\.id) == ["R1"])
            }
            let result = Operations(backend: backend, journalURL: url).execute(.list(.clearCompleted("Inbox", confirmed: true)))
            #expect(result.status == .ok); #expect(backend.deleteCalls == [["R1"]])
            #expect(backend.items["late"] != nil); #expect(backend.actions.isEmpty)
        }
    }
    @Test func reconciliationQueriesOutsideLockAndPreservesConcurrentEntries() throws {
        try fixture { backend, url in
            let journal = DeletionJournal(url: url)
            let original = DeletionEntry(id: "R1", title: "Old", listID: "L1", parentID: nil, time: Date(), state: .pending)
            let changedState = DeletionEntry(id: "state", title: "State", listID: "L1", parentID: nil, time: Date(), state: .confirmed)
            let absent = DeletionEntry(id: "gone", title: "Gone", listID: "L1", parentID: nil, time: Date(), state: .confirmed)
            try journal.transaction { $0 = [original, changedState, absent] }
            backend.deletedItems["R1"] = backend.items["R1"]
            let interleave = ReconciliationInterleave(url: url)
            var timedOut = false
            backend.recoveryLookup = { id in
                guard id == "R1" else { return }
                DispatchQueue.global().async { interleave.update() }
                if interleave.done.wait(timeout: .now() + 3) == .timedOut {
                    timedOut = true
                    throw Failure(.backend, "Concurrent journal update blocked by recovery lookup")
                }
            }
            let result = Operations(backend: backend, journalURL: url).execute(.deleted)
            if timedOut { _ = interleave.done.wait(timeout: .now() + 3) }
            #expect(!timedOut); #expect(interleave.error == nil); #expect(result.status == .ok)
            let entries = try journal.read()
            #expect(Set(entries.map(\.id)) == ["R1", "state", "new"])
            #expect(entries.first { $0.id == "R1" }?.title == "Changed during lookup")
            #expect(entries.first { $0.id == "R1" }?.state == .pending)
            #expect(entries.first { $0.id == "state" }?.state == .pending)
            if case .deleted(let output) = result.result { #expect(Set(output.entries.map(\.id)) == ["R1", "state", "new"]) }
            else { Issue.record("Expected reconciled entries") }
        }
    }
    @Test func bulkClearReplacesMatchingJournalEntriesAndConfirmsSnapshot() throws {
        try fixture { backend, url in
            backend.items = [:]
            let journal = DeletionJournal(url: url)
            let oldTime = Date(timeIntervalSince1970: 1)
            let count = 300
            for index in 0..<count {
                let id = "R\(index)"
                backend.items[id] = Reminder(id: id, fields: ReminderFields(title: id, listID: "L1", completed: true))
            }
            try journal.transaction { entries in
                entries = (0..<count).map { DeletionEntry(id: "r\($0)", title: "old", listID: "L1", parentID: nil, time: oldTime, state: .confirmed) }
                entries.append(DeletionEntry(id: "other", title: "Keep", listID: "L2", parentID: nil, time: oldTime, state: .pending))
            }
            backend.beforeDelete = {
                let entries = try journal.read()
                #expect(entries.count == count + 1)
                #expect(entries.filter { $0.id != "other" }.allSatisfy { $0.state == .pending && $0.title == $0.id })
            }
            let result = Operations(backend: backend, journalURL: url).execute(.list(.clearCompleted("Inbox", confirmed: true)))
            #expect(result.status == .ok); #expect(backend.deleteCalls.count == 1)
            let entries = try journal.read()
            #expect(entries.count == count + 1)
            #expect(entries.filter { $0.id != "other" }.allSatisfy { $0.state == .confirmed })
            #expect(entries.first { $0.id == "other" }?.state == .pending)
        }
    }
    @Test func listDeleteUnexpectedReceiptPreservesPendingEvidenceAndReturnsUnknown() throws {
        try fixture { backend, url in
            backend.listReceiptIDs = ["L1", "R1", "late"]
            let result = Operations(backend: backend, journalURL: url).execute(.list(.delete("Inbox", confirmed: true)))
            #expect(result.status == .unknown); #expect(result.error?.underlyingCode == .conflict)
            #expect(Set(result.error?.affectedIDs ?? []) == ["L1", "R1", "late"])
            guard case .mutation(let receipt) = result.result else { Issue.record("Expected retained receipt"); return }
            #expect(Set(receipt.affectedIDs) == ["L1", "R1", "late"])
            let entries = try DeletionJournal(url: url).read()
            #expect(entries.map(\.id) == ["R1"]); #expect(entries.first?.state == .pending)
        }
    }
    @Test func testContainerDeletionAlsoJournalsBeforeNativeAndPersistenceFailureAborts() throws {
        try fixture { backend, url in
            let engine = Operations(backend: backend, journalURL: url)
            try Data("bad".utf8).write(to: url)
            #expect(engine.execute(.list(.delete("Inbox", confirmed: true))).error?.code == .io)
            #expect(backend.mutationCalls == 0)
            try FileManager.default.removeItem(at: url)
            backend.beforeMutation = { #expect((try? DeletionJournal(url: url).read().map(\.id)) == ["R1"]) }
            #expect(engine.execute(.list(.delete("Inbox", confirmed: true))).status == .ok)
        }
    }
}
