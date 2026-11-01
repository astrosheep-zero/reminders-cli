import Foundation
import Testing
import ReminderCore
import ReminderKitShim
@testable import ReminderNative

/// Exercises the real Swift adapter through its actual ObjC boundary, without
/// loading ReminderKit, constructing REMStore, or invoking authorization APIs.
private final class OfflineBridge: RNBridge {
    var rows: [String: [String: Any]] = [:]
    var hidden: [String: [String: Any]] = [:]
    var receipt: [String] = []
    var introduced: [String] = []
    var patch: [AnyHashable: Any] = [:]
    var catalogReads: [CatalogScope] = []
    var sectionLists: [String?] = []
    var sectionUpdates: [(String, String, [AnyHashable: Any])] = []
    var defaultReads = 0
    var tagReads = 0
    var selectedTagIDs: [String] = []
    var tagQueries: [([String], [String], Bool)] = []
    var tagError: Error?
    var reminderListReads = 0
    var queryRows: [[String: Any]] = []
    var visitedIDs: [String] = []
    var readBatches: [[String]] = []
    var smartIDs: [String] = []
    var searchCriteria: [[String: Any]] = []
    var searchPage: (Int, Int)?
    var imageByteReads = 0
    var savedIDs: [String] = []
    var savedParentID: String?
    var afterUpdate: (() -> Void)?
    var afterRestore: (() -> Void)?
    override var lastSavedReminderIDs: [String] { receipt }
    override var lastIntroducedReminderIDs: [String] { introduced }
    override func reminder(_ identifier: String, concealed: Bool, imageBytes: Bool) throws -> Any {
        if imageBytes { imageByteReads += 1 }
        return (concealed ? hidden[identifier] : rows[identifier]) as Any? ?? NSNull()
    }
    override func lists() throws -> [[String: Any]] {
        catalogReads.append(.lists)
        return [["id": "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", "name": "Inbox", "pinned": false, "groceries": false,
          "members": [[String: Any]](), "sections": [[String: Any]](), "sorting": "manual"]]
    }
    override func defaultList() throws -> String { defaultReads += 1; return "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB" }
    override func groups() throws -> [[String: Any]] { catalogReads.append(.groups); return [] }
    var smartError: Error?
    override func smartLists() throws -> [[String: Any]] { catalogReads.append(.smartLists); if let smartError { throw smartError }; return [] }
    override func sections(inList listID: String?) throws -> [[String: Any]] {
        catalogReads.append(.sections); sectionLists.append(listID)
        return [["id": "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC", "name": "Section", "listID": "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"]]
    }
    var templateRows: [[String: Any]] = []
    override func templates() throws -> [[String: Any]] { catalogReads.append(.templates); return templateRows }
    override func tagCounts() throws -> [[String: Any]] { catalogReads.append(.tags); tagReads += 1; return [["name": "work", "openCount": 3, "totalCount": 5]] }
    override func reminderIDs(withIncludedTags include: [String], excludedTags exclude: [String], matchAll: Bool) throws -> [String] {
        tagQueries.append((include, exclude, matchAll)); if let tagError { throw tagError }; return selectedTagIDs
    }
    override func contents(ofSmartList identifier: String, includeCompleted: Bool) throws -> [String] { smartIDs }
    override func searchReminders(criteria: [[String: Any]], limit: Int, offset: Int) throws -> [[String: Any]] {
        searchCriteria = criteria; searchPage = (limit, offset); return queryRows
    }
    override func reminders(inList listID: String?, identifiers: [String]?) throws -> [[String: Any]] {
        if let identifiers { readBatches.append(identifiers) } else { reminderListReads += 1 }
        let selected = try identifiers.map { ids in try ids.map { id in
            guard let row = rows[id] ?? queryRows.first(where: { $0["id"] as? String == id }) else {
                throw Failure(.notFound, "Missing requested reminder")
            }
            return row
        } } ?? queryRows
        visitedIDs += selected.map { $0["id"] as! String }
        return selected
    }
    override func updateReminder(_ identifier: String, changes: [AnyHashable: Any]) throws {
        patch = changes; afterUpdate?()
    }
    override func updateSection(_ identifier: String, list listID: String, changes: [AnyHashable: Any]) throws {
        sectionUpdates.append((identifier, listID, changes))
    }
    override func createReminder(inList listID: String, title: String, changes: [AnyHashable: Any]) throws -> String {
        savedIDs = receipt; return receipt[0]
    }
    override func restoreReminders(_ identifiers: [String], toList listID: String, parentID: String?) throws {
        savedIDs = identifiers; savedParentID = parentID; afterRestore?()
    }
    var tagSelection: [String]?
    override func replaceTag(_ name: String, replacement: String?) throws -> [String] { tagSelection ?? receipt }
}

struct NativeBackendTests {
    let root = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    let child = "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"
    let list = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
    func row(_ id: String, title: String = "Task", parent: String? = nil, completed: Bool = false) -> [String: Any] {
        var result: [String: Any] = ["id": id, "listID": list, "title": title, "priority": 0, "flagged": false,
            "urgent": false, "completed": completed, "tags": [String](), "early": [[Int]](), "urls": [String](), "images": [[String: Any]](), "childIDs": [String]()]
        result["parentID"] = parent; return result
    }
    private func backend(_ bridge: OfflineBridge) -> NativeReminderBackend {
        NativeReminderBackend(openBridge: { bridge }, permission: { "fullAccess" })
    }
    @Test func findUsesNativeCriteriaOrderAndPaginationWithoutLocalFiltering() throws {
        let bridge = OfflineBridge()
        // A native match need not contain the literal query in its title/notes.
        bridge.queryRows = [row(child, title: "Native first"), row(root, title: "Native second")]
        var query = ReminderQuery(); query.text = "needle"; query.matching = .prefix; query.list = list
        query.flagged = false; query.hasDueDate = true; query.limit = 2; query.offset = 7
        #expect(try backend(bridge).find(query).map(\.id) == [child, root])
        #expect(bridge.searchPage?.0 == 2); #expect(bridge.searchPage?.1 == 7)
        #expect(bridge.searchCriteria as NSArray == [
            ["base": "textualField", "arg0": "needle", "arg1": 1],
            ["base": "listID", "arg0": ["entityName": "REMList", "uuid": list], "arg1": ["includeForSiri": [:]]],
            ["base": "isCompleted", "arg0": false], ["base": "isFlagged", "arg0": false],
            ["base": "hasDueDate", "arg0": true]
        ] as NSArray)
        #expect(bridge.reminderListReads == 0); #expect(bridge.visitedIDs.isEmpty)
        bridge.queryRows = [["id": root]]
        #expect(throws: Failure.self) { try backend(bridge).find(query) }
    }
    @Test func textMatchingMapsToNativeCriteria() throws {
        for (matching, style): (SearchMatching?, Int) in [(nil, 2), (.exact, 0), (.prefix, 1), (.word, 2)] {
            let bridge = OfflineBridge(); var q = ReminderQuery(); q.text = "place"; q.matching = matching
            _ = try backend(bridge).find(q)
            #expect(bridge.searchCriteria.first as NSDictionary? == ["base": "textualField", "arg0": "place", "arg1": style] as NSDictionary)
        }
    }
    @Test func tagSelectionShortCircuitsEmptyAndPaginatesUnconstrainedNativeIDs() throws {
        let bridge = OfflineBridge(), backend = backend(bridge)
        var q = ReminderQuery(); q.tags = ["work", "home"]; q.excludeTags = ["blocked"]
        #expect(try backend.find(q).isEmpty); #expect(bridge.searchPage == nil); #expect(bridge.readBatches.isEmpty)
        #expect(bridge.tagQueries[0].0 == ["work", "home"]); #expect(bridge.tagQueries[0].1 == ["blocked"]); #expect(bridge.tagQueries[0].2)
        bridge.selectedTagIDs = [root, child, list]; bridge.queryRows = [row(child)]
        q.includeCompleted = true; q.tagMatch = .any; q.offset = 1; q.limit = 1
        #expect(try backend.find(q).map(\.id) == [child]); #expect(bridge.readBatches == [[child]])
        #expect(bridge.tagQueries.last?.2 == false); #expect(bridge.searchPage == nil); #expect(bridge.reminderListReads == 0)
        q.offset = 10
        #expect(try backend.find(q).isEmpty); #expect(bridge.readBatches.last == [])
    }
    @Test func tagSelectionIntersectsOtherCriteriaAndCompletionInNativeSearch() throws {
        let bridge = OfflineBridge(), backend = backend(bridge); bridge.selectedTagIDs = [root, child]
        bridge.queryRows = [row(child, title: "Native match")]
        var defaults = ReminderQuery(); defaults.tags = ["work"]
        _ = try backend.find(defaults)
        #expect(bridge.searchCriteria.first as NSDictionary? == ["base": "isCompleted", "arg0": false] as NSDictionary)
        #expect(bridge.searchCriteria.last?["base"] as? String == "objectID"); #expect(bridge.readBatches.isEmpty)
        bridge.tagQueries = []
        var q = ReminderQuery(); q.excludeTags = ["blocked"]; q.text = "needle"
        q.list = list; q.flagged = false; q.offset = 3; q.limit = 2
        #expect(try backend.find(q).map(\.id) == [child])
        #expect(bridge.tagQueries.first?.0 == []); #expect(bridge.tagQueries.first?.1 == ["blocked"])
        #expect(bridge.searchCriteria as NSArray == [
            ["base": "textualField", "arg0": "needle", "arg1": 2],
            ["base": "listID", "arg0": ["entityName": "REMList", "uuid": list], "arg1": ["includeForSiri": [:]]],
            ["base": "isCompleted", "arg0": false], ["base": "isFlagged", "arg0": false],
            ["base": "objectID", "arg0": [["entityName": "REMReminder", "uuid": root], ["entityName": "REMReminder", "uuid": child]]]
        ] as NSArray)
        #expect(bridge.searchPage?.0 == 2); #expect(bridge.searchPage?.1 == 3); #expect(bridge.readBatches.isEmpty)
        bridge.tagError = Failure(.backend, "Tag selection failed")
        #expect(throws: Failure.self) { try backend.find(q) }
        #expect(bridge.reminderListReads == 0)
    }
    @Test func sectionEditSendsOneSparseChangesDictionaryToBridge() throws {
        let bridge = OfflineBridge(), backend = backend(bridge)
        let cases: [(SectionPatch, [String: Any])] = [
            (SectionPatch(name: "Renamed"), ["name": "Renamed"]),
            (SectionPatch(position: .before(root)), ["position": ["id": root, "after": false]]),
            (SectionPatch(name: "Renamed", position: .after(root)), ["name": "Renamed", "position": ["id": root, "after": true]])]
        for (patch, expected) in cases {
            let count = bridge.sectionUpdates.count
            #expect(try backend.section(.update(list: list, section: child, patch: patch)).affectedIDs == [child])
            #expect(bridge.sectionUpdates.count == count + 1)
            let update = try #require(bridge.sectionUpdates.last)
            #expect(update.0 == child); #expect(update.1 == list)
            #expect(update.2 as NSDictionary == expected as NSDictionary)
        }
        #expect(throws: Failure.self) { try backend.section(.update(list: list, section: child, patch: SectionPatch())) }
        #expect(bridge.sectionUpdates.count == 3)
        #expect(bridge.catalogReads.isEmpty)
    }
    @Test func eachCatalogFamilyReadsOnlyItsNativeFamily() throws {
        for scope in CatalogScope.allCases {
            let bridge = OfflineBridge(), backend = backend(bridge)
            _ = try backend.catalog([scope], listID: scope == .sections ? list : nil)
            #expect(Set(bridge.catalogReads) == (scope == .all ? Set(CatalogScope.allCases.filter { $0 != .all }) : [scope]))
            #expect(bridge.defaultReads == (scope == .all || scope == .lists ? 1 : 0))
            #expect(bridge.reminderListReads == 0)
            if scope == .sections { #expect(bridge.sectionLists == [list]) }
        }
        let bridge = OfflineBridge(); bridge.smartError = Failure(.unsupported, "Unrepresentable smart filter")
        #expect(try backend(bridge).catalog([.lists]).lists.count == 1)
        #expect(throws: Failure.self) { try backend(bridge).catalog([.smartLists]) }
    }
    @Test func completionCriterionHasThreeStatesAndExplicitCompletedTakesPrecedence() throws {
        let bridge = OfflineBridge(), backend = backend(bridge)
        bridge.queryRows = [row(root, completed: true)]
        for (includeCompleted, completed, expected): (Bool, Bool?, Bool?) in [(false, nil, false), (true, nil, nil), (false, true, true), (true, false, false)] {
            var query = ReminderQuery(); query.includeCompleted = includeCompleted; query.completed = completed
            #expect(try backend.find(query).first?.fields.completed == true)
            let criteria = bridge.searchCriteria.filter { $0["base"] as? String == "isCompleted" }
            #expect(criteria.count == (expected == nil ? 0 : 1))
            #expect(criteria.first?["arg0"] as? Bool == expected)
        }
    }
    @Test func smartFindSlicesNativeIDsBeforeReadingAndRejectsCriteriaCombination() throws {
        let bridge = OfflineBridge()
        bridge.queryRows = [row(root), row(child), ["id": list]]
        bridge.smartIDs = [root, child, list]
        var query = ReminderQuery(); query.smartList = list; query.offset = 1; query.limit = 1
        #expect(try backend(bridge).find(query).map(\.id) == [child])
        #expect(bridge.visitedIDs == [child])
        for completed in [false, true] {
            query.completed = completed
            #expect(throws: Failure.self) { try backend(bridge).find(query) }
        }
        query.completed = nil; query.text = "Unsupported combination"
        #expect(throws: Failure.self) { try backend(bridge).find(query) }
    }
    @Test func metadataCatalogNeverHydratesUnrelatedReminderOrTags() throws {
        let bridge = OfflineBridge(), backend = backend(bridge)
        #expect(try backend.catalog([.lists]).tags.isEmpty)
        #expect(bridge.tagReads == 0)
        #expect(bridge.reminderListReads == 0)
        #expect(try backend.catalog([.tags]).tags == [Tag(name: "work", openCount: 3, totalCount: 5)])
        #expect(bridge.tagReads == 1)
        #expect(bridge.reminderListReads == 0)
    }
    @Test func templateAppearanceUsesTheSameColorProjectionAsLists() throws {
        let bridge = OfflineBridge()
        bridge.templateRows = [["id": root, "name": "Custom", "color": ["name": "custom", "hex": "#123456"], "icon": "star"],
            ["id": child, "name": "Blue", "color": ["name": "lightBlue"]], ["id": list, "name": "Plain"]]
        #expect(try backend(bridge).catalog([.templates]).templates == [
            NamedEntity(id: root, name: "Custom", color: "#123456", icon: "star"),
            NamedEntity(id: child, name: "Blue", color: "light-blue"), NamedEntity(id: list, name: "Plain")])
    }
    @Test func ordinaryReadsUseImageMetadataAndExplicitImageReadsBytes() throws {
        let bridge = OfflineBridge(), backend = backend(bridge)
        var raw = row(root)
        raw["images"] = [["id": child, "fileName": "x.png", "type": "public.png", "size": 3]]
        bridge.rows[root] = raw
        let item = try #require(try backend.reminder(id: root))
        #expect(item.images[0].byteCount == 3)
        #expect(bridge.imageByteReads == 0)
        raw["images"] = [["id": child, "fileName": "x.png", "type": "public.png", "size": 3, "data": Data([1, 2, 3])]]
        bridge.rows[root] = raw
        #expect(try backend.image(reminderID: root, imageID: child).bytes == Data([1, 2, 3]))
        #expect(bridge.imageByteReads == 1)
    }
    @Test func titlePatchAndOperationOwnedReceiptsNeverScanLists() throws {
        let bridge = OfflineBridge(); bridge.rows[root] = row(root)
        bridge.receipt = [root, child]; bridge.rows[child] = row(child, title: "Touched parent")
        var patch = ReminderPatch(); patch.title = .set("Edited")
        let result = try backend(bridge).updateReminder(id: root, patch: patch)
        #expect(bridge.patch.keys.compactMap { $0 as? String }.sorted() == ["title"])
        #expect(Set(result.affectedIDs) == [root, child])
        #expect(bridge.reminderListReads == 0)
        #expect(bridge.readBatches == [[root, child]])
    }
    @Test func tagReceiptUsesRequestSelectionNotAnEarlierSnapshot() throws {
        let bridge = OfflineBridge(); bridge.receipt = [child]; bridge.rows[child] = row(child)
        let result = try backend(bridge).tag(.rename("work", name: "job"))
        #expect(result.affectedIDs == [child])
        #expect(bridge.reminderListReads == 0)
        bridge.tagSelection = [root]
        do { _ = try backend(bridge).tag(.rename("work", name: "job")); Issue.record("Different same-sized receipt must fail") }
        catch let failure as Failure {
            #expect(failure.code == .outcomeUnknown)
            #expect(Set(failure.affectedIDs) == [root, child])
        }
    }
    @Test func creationIncludesAllRequestOwnedAffectedIDs() throws {
        let bridge = OfflineBridge(); bridge.receipt = [root, child]
        bridge.rows[root] = row(root); bridge.rows[child] = row(child)
        let result = try backend(bridge).createReminder(ReminderDraft(fields: ReminderFields(title: "Task", listID: list)))
        #expect(Set(result.affectedIDs) == [root, child])
    }
    @Test func independentlyDeletedChildRestorePreservesActiveParent() throws {
        let bridge = OfflineBridge(); bridge.hidden[child] = row(child); bridge.receipt = [child, root]
        bridge.afterRestore = {
            bridge.rows[self.child] = self.row(self.child, parent: self.root)
            var parent = self.row(self.root); parent["childIDs"] = [self.child]; bridge.rows[self.root] = parent
        }
        let result = try backend(bridge).restoreReminder(id: child, listID: list, knownChildIDs: [], parentID: root)
        #expect(result.reminders.first(where: { $0.id == child })?.fields.parentID == root)
        #expect(Set(result.affectedIDs) == [child, root])
        #expect(bridge.savedIDs == [child])
        #expect(bridge.savedParentID == root)
    }
    @Test func restoreMissingReadbackRemainsUnknownWithEveryKnownID() throws {
        let bridge = OfflineBridge(); var deletedRoot = row(root); deletedRoot["childIDs"] = [child]
        bridge.hidden[root] = deletedRoot
        bridge.afterRestore = { bridge.rows[self.root] = self.row(self.root) }
        do { _ = try backend(bridge).restoreReminder(id: root, listID: list, knownChildIDs: [child], parentID: nil); Issue.record("Missing child must not disappear from confirmation") }
        catch let failure as Failure {
            #expect(failure.code == .outcomeUnknown)
            #expect(Set(failure.affectedIDs) == [root, child])
        }
        #expect(bridge.savedIDs == [root, child])
    }
    @Test func recurringCompletionRequiresCopyFromItsOwnRequest() throws {
        let bridge = OfflineBridge(); var before = row(root)
        before["repeat"] = ["frequency": 0, "interval": 1, "weekdays": [[Int]]()]
        bridge.rows[root] = before; bridge.receipt = [root, child]; bridge.introduced = [child]
        bridge.afterUpdate = { bridge.rows[self.child] = self.row(self.child, completed: true) }
        var patch = ReminderPatch(); patch.completed = .set(true)
        let result = try backend(bridge).updateReminder(id: root, patch: patch)
        #expect(Set(result.affectedIDs) == [root, child])
        #expect(bridge.reminderListReads == 0)
        // An existing touched record, even one with matching completed fields,
        // is not evidence of a newly generated recurring copy.
        bridge.introduced = []; bridge.afterUpdate = nil
        do { _ = try backend(bridge).updateReminder(id: root, patch: patch); Issue.record("No copy evidence must be uncertain") }
        catch let failure as Failure { #expect(failure.code == .outcomeUnknown) }
    }
}
