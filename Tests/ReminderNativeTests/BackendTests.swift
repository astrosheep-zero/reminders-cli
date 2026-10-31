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
    var tagReads = 0
    var reminderListReads = 0
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
        [["id": "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", "name": "Inbox", "pinned": false, "groceries": false,
          "members": [[String: Any]](), "sections": [[String: Any]](), "sorting": "manual"]]
    }
    override func defaultList() throws -> String { "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB" }
    override func groups() throws -> [[String: Any]] { [] }
    override func smartLists() throws -> [[String: Any]] { [] }
    override func templates() throws -> [[String: Any]] { [] }
    override func tagCounts() throws -> [[String: Any]] { tagReads += 1; return [["name": "work", "openCount": 3, "totalCount": 5]] }
    override func reminders(inList listID: String) throws -> [[String: Any]] {
        reminderListReads += 1
        throw Failure(.backend, "Full-list hydration must not occur in these tests")
    }
    override func updateReminder(_ identifier: String, changes: [AnyHashable: Any]) throws {
        patch = changes; afterUpdate?()
    }
    override func createReminder(inList listID: String, title: String, changes: [AnyHashable: Any]) throws -> String {
        savedIDs = receipt; return receipt[0]
    }
    override func restoreReminders(_ identifiers: [String], toList listID: String, parentID: String?) throws {
        savedIDs = identifiers; savedParentID = parentID; afterRestore?()
    }
    override func replaceTag(_ name: String, replacement: String?) throws -> NSNumber { NSNumber(value: receipt.count) }
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
    @Test func metadataCatalogNeverHydratesUnrelatedReminderOrTags() throws {
        let bridge = OfflineBridge(), backend = backend(bridge)
        #expect(try backend.catalog(includeTags: false).tags.isEmpty)
        #expect(bridge.tagReads == 0)
        #expect(bridge.reminderListReads == 0)
        #expect(try backend.catalog(includeTags: true).tags == [Tag(name: "work", openCount: 3, totalCount: 5)])
        #expect(bridge.tagReads == 1)
        #expect(bridge.reminderListReads == 0)
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
    }
    @Test func tagReceiptUsesRequestSelectionNotAnEarlierSnapshot() throws {
        let bridge = OfflineBridge(); bridge.receipt = [child]; bridge.rows[child] = row(child)
        let result = try backend(bridge).tag(.rename("work", name: "job"))
        #expect(result.affectedIDs == [child])
        #expect(bridge.reminderListReads == 0)
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
