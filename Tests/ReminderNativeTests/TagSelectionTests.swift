import Foundation
import Testing
import ReminderKitShim

private final class TagIdentity: NSObject {
    @objc let uuid = NSUUID()
}

private final class TestTag: NSObject {
    @objc let objectID = TagIdentity()
    @objc let name: String
    init(_ name: String) { self.name = name }
}

private final class TaggedReminder: NSObject {
    @objc let hashtags: [TestTag]
    init(_ hashtags: [TestTag]) { self.hashtags = hashtags }
}

private final class TagContext: NSObject {
    var removed: [TestTag] = []
    var added: [String] = []
    @objc(removeHashtag:) func remove(_ tag: TestTag) { removed.append(tag) }
    @objc(addHashtagWithType:name:) func add(_ type: Int, name: String) -> NSObject {
        added.append(name)
        return NSObject()
    }
}

private final class TagChange: NSObject {
    @objc let hashtagContext = TagContext()
}

private final class TagRequest: NSObject {
    let change = TagChange()
    @objc(updateReminder:) func update(_ reminder: TaggedReminder) -> TagChange { change }
}

private final class TagSelectionBridge: RNBridge {
    let source = TestTag("native alias")
    let target = TestTag("existing target alias")
    let unrelated = TestTag("unrelated")
    let fakeRequest = TagRequest()
    var selected = ["row"]
    var rows: [String: TaggedReminder] = [:]
    var sourceIDs: Set<String> = []
    var targetIDs: Set<String> = []
    var cached: [String] = []
    var commits = 0

    @objc(reminderIDsForTag:) func selectedIDs(_ name: String) -> [String] { selected }
    @objc(hashtagIDsForNames:) func tagIDs(_ names: [String]) -> NSSet {
        NSSet(set: names == ["source"] ? sourceIDs : targetIDs)
    }
    @objc(cacheReminders:concealed:) func cache(_ ids: [String], concealed: Bool) {
        cached = ids
        #expect(!concealed)
    }
    @objc(existingReminder:) func existing(_ id: String) -> TaggedReminder? { rows[id] }
    @objc(request) func fakeRequestValue() -> TagRequest { fakeRequest }
    @objc(commit:) func commit(_ request: TagRequest) { commits += 1 }
}

@Suite("Native tag selection (no store)")
struct TagSelectionTests {
    @Test func nativeIdentityControlsRemovalAndAvoidsDuplicateReplacement() throws {
        let bridge = TagSelectionBridge()
        bridge.sourceIDs = [bridge.source.objectID.uuid.uuidString]
        bridge.targetIDs = [bridge.target.objectID.uuid.uuidString]
        bridge.rows["row"] = TaggedReminder([bridge.source, bridge.target, bridge.unrelated])

        let selected = try bridge.replaceTag("source", replacement: "replacement")
        #expect(selected == ["row"])
        #expect(bridge.cached == ["row"])
        #expect(bridge.fakeRequest.change.hashtagContext.removed == [bridge.source])
        #expect(bridge.fakeRequest.change.hashtagContext.added.isEmpty)
        #expect(bridge.commits == 1)
    }

    @Test func selectedReminderWithoutMatchingTagFailsBeforeCommit() {
        let bridge = TagSelectionBridge()
        bridge.sourceIDs = [bridge.source.objectID.uuid.uuidString]
        bridge.rows["row"] = TaggedReminder([bridge.unrelated])

        #expect(throws: (any Error).self) {
            try bridge.replaceTag("source", replacement: "replacement")
        }
        #expect(bridge.fakeRequest.change.hashtagContext.removed.isEmpty)
        #expect(bridge.fakeRequest.change.hashtagContext.added.isEmpty)
        #expect(bridge.commits == 0)
    }
}
