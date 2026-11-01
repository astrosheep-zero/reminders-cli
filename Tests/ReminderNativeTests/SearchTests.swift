import Foundation
import Testing
import ReminderKitShim

private final class SearchIdentity: NSObject {
    @objc let uuid = NSUUID()
}
private final class SearchObject: NSObject {
    @objc let objectID = SearchIdentity()
    @objc let listID = SearchIdentity()
    @objc var parentReminderID: SearchIdentity?
    @objc var isCompleted = false
}
private final class SearchReply: NSObject {
    @objc var resultData = Data()
}
private final class SearchStore: NSObject {
    let reply = SearchReply()
    var objects: [String: SearchObject] = [:]
    var batches: [[String]] = []
    var failure: NSError?
    var queryResults: [String: Any] = [:]
    var titleCandidates: [SearchObject] = []
    var parameters: [[String: Any]] = []
    @objc(fetchRemindersMatchingPredicateDescriptor:sortDescriptors:options:error:)
    func matching(_ predicate: NSObject, sort: NSArray, options: NSObject,
                  error: AutoreleasingUnsafeMutablePointer<NSError?>?) -> [SearchObject] { titleCandidates }
    @objc(resultFromPerformingSwiftInvocation:parametersData:storages:error:)
    func search(_ invocation: NSObject, data: Data, storages: NSDictionary,
                error: AutoreleasingUnsafeMutablePointer<NSError?>?) -> NSObject {
        let parameters = try! PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
        self.parameters.append(parameters)
        if !queryResults.isEmpty {
            let key = (parameters["include"] as? [String])?.first ?? "labels"
            let selected = SearchReply()
            selected.resultData = try! PropertyListSerialization.data(fromPropertyList: queryResults[key]!, format: .binary, options: 0)
            return selected
        }
        return reply
    }
    @objc(fetchRemindersWithObjectIDs:fetchOptions:error:)
    func fetch(_ ids: [String], options: NSObject, error: AutoreleasingUnsafeMutablePointer<NSError?>?) -> NSDictionary? {
        batches.append(ids); error?.pointee = failure
        return objects.filter { ids.contains($0.key) } as NSDictionary
    }
}
private final class SearchBridge: RNBridge {
    @objc(reminderObjectID:) func identity(_ identifier: String) -> NSString { identifier as NSString }
    @objc(list:) func list(_ identifier: String) -> NSObject { NSObject() }
    @objc(rawSections:) func sections(_ list: NSObject) -> [NSObject] { [] }
    @objc(reminderValue:concealed:imageBytes:)
    func value(_ object: SearchObject, concealed: Bool, imageBytes: Bool) -> NSDictionary {
        ["id": object.objectID.uuid.uuidString, "hydrated": true]
    }
}

struct NativeSearchTests {
    @Test func nativeTitleAndTagSelectionsUseBatchReadsIncludingCompletedAndZeroCountLabels() throws {
        var error: NSError?
        #expect(RNPreflight(["reminder.title", "tags.read"], &error))
        let bridge = SearchBridge(), store = SearchStore(), first = SearchObject(), second = SearchObject()
        bridge.setValue(store, forKey: "_store")
        let ids = [first, second].map { $0.objectID.uuid.uuidString }
        store.objects = [ids[0]: first, ids[1]: second]; second.isCompleted = true
        store.titleCandidates = [second, first]
        #expect(try bridge.reminders(matchingTitle: "native match").compactMap { $0["id"] as? String } == Array(ids.reversed()))
        #expect(store.batches == [Array(ids.reversed())])
        store.batches = []
        store.queryResults = ["labels": [["name": "A"], ["name": "B"], ["name": "Empty"]],
                              "A": ids.map { ["uuid": $0] }, "B": [["uuid": ids[1]]], "Empty": []]
        let tags = try bridge.tagCounts()
        #expect(tags.map { $0["name"] as! String } == ["A", "B", "Empty"])
        #expect(tags.map { $0["openCount"] as! Int } == [1, 0, 0])
        #expect(tags.map { $0["totalCount"] as! Int } == [2, 1, 0])
        #expect(store.batches.count == 1)
        #expect(Set(store.batches[0]) == Set(ids))
    }
    @Test func nativeTagQueryEncodesIncludeExcludeAndMatchWithoutHydration() throws {
        let bridge = SearchBridge(), store = SearchStore(), ids = [UUID().uuidString, UUID().uuidString]
        bridge.setValue(store, forKey: "_store")
        store.reply.resultData = try PropertyListSerialization.data(fromPropertyList: ids.map { ["uuid": $0] }, format: .binary, options: 0)
        for all in [true, false] {
            #expect(try bridge.reminderIDs(withIncludedTags: ["work", "home"], excludedTags: ["blocked"], matchAll: all) == ids)
            #expect(store.parameters.last as NSDictionary? == ["include": ["work", "home"], "exclude": ["blocked"], "operation": [all ? "all" : "any": [:]]] as NSDictionary)
        }
        #expect(try bridge.reminderIDs(withIncludedTags: [], excludedTags: ["blocked"], matchAll: true) == ids)
        #expect(store.parameters.last?["include"] as? [String] == []); #expect(store.batches.isEmpty)
        store.reply.resultData = try PropertyListSerialization.data(fromPropertyList: [["uuid": "bad"]], format: .binary, options: 0)
        #expect(throws: (any Error).self) { try bridge.reminderIDs(withIncludedTags: ["work"], excludedTags: [], matchAll: true) }
    }
    @Test func nativePageHydratesOnceInSearchOrderAndRejectsMissingOrWrongObjects() throws {
        // Real invocation/serialization/guard, fake store edges; never opens REMStore.
        let bridge = SearchBridge(), store = SearchStore(), first = SearchObject(), second = SearchObject()
        bridge.setValue(store, forKey: "_store")
        let ids = [second, first].map { $0.objectID.uuid.uuidString }
        store.reply.resultData = try PropertyListSerialization.data(fromPropertyList: ids.map { ["objectIDUUID": $0] }, format: .binary, options: 0)
        store.objects = [ids[0]: second, ids[1]: first]
        let rows = try bridge.searchReminders(criteria: [], limit: 2, offset: 3)
        #expect(rows.compactMap { $0["id"] as? String } == ids)
        #expect(store.batches == [ids])
        #expect(bridge.value(forKey: "_activeCache") == nil)
        store.batches = []
        let receipt = try bridge.reminders(inList: nil, identifiers: ids)
        #expect(receipt.compactMap { $0["id"] as? String } == ids)
        #expect(store.batches == [ids])
        store.batches = []
        #expect(try bridge.reminders(inList: nil, identifiers: []).isEmpty)
        #expect(store.batches.isEmpty)
        store.objects[ids[0]] = nil
        #expect(throws: (any Error).self) { try bridge.searchReminders(criteria: [], limit: 2, offset: 3) }
        store.objects[ids[0]] = first
        #expect(throws: (any Error).self) { try bridge.searchReminders(criteria: [], limit: 2, offset: 3) }
        store.objects[ids[0]] = second; store.failure = NSError(domain: "native.test", code: 7)
        #expect(throws: (any Error).self) { try bridge.searchReminders(criteria: [], limit: 2, offset: 3) }
        store.reply.resultData = try PropertyListSerialization.data(fromPropertyList: [["objectIDUUID": "bad"]], format: .binary, options: 0)
        #expect(throws: (any Error).self) { try bridge.searchReminders(criteria: [], limit: 2, offset: 3) }
    }
}
