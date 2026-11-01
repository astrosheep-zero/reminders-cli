import Foundation
import Testing
import ReminderKitShim

private final class CatalogIdentity: NSObject {
    @objc let uuid = NSUUID()
}
private final class CatalogStorage: NSObject {
    @objc let name = "List"
    @objc let shouldCategorizeGroceryItems = false
    @objc let sortingStyle = "manual"
}
private final class CatalogList: NSObject {
    @objc let objectID = CatalogIdentity()
    @objc let storage = CatalogStorage()
    @objc let isGroup = false
    @objc let isShared = false
    @objc let isPinned = false
    @objc var shareeContext: NSObject?
    @objc var parentList: NSObject?
    @objc var color: NSObject?
    @objc var badgeEmblem: String?
}
/// Replaces only native store/list edges; exercises the current public bridge methods.
private final class CatalogBridge: RNBridge {
    let rows = [CatalogList(), CatalogList()]
    var enumerations = 0
    var sectionReads: [String] = []
    @objc(rawLists) func rawLists() -> [CatalogList] { enumerations += 1; return rows }
    @objc(list:) func list(_ id: String) -> CatalogList { rows.first { $0.objectID.uuid.uuidString == id }! }
    @objc(sectionValues:) func sectionValues(_ list: CatalogList) -> [[String: Any]] {
        let id = list.objectID.uuid.uuidString; sectionReads.append(id)
        return [["id": UUID().uuidString, "name": "Section", "listID": id]]
    }
}

struct NativeCatalogTests {
    @Test func listMetadataDoesNotReadSectionsInsideTheObjCBridge() throws {
        let bridge = CatalogBridge()
        let rows = try bridge.lists()
        #expect(rows.count == 2); #expect(rows.allSatisfy { $0["name"] as? String == "List" })
        #expect(bridge.enumerations == 1); #expect(bridge.sectionReads.isEmpty)
    }
    @Test func scopedSectionsVisitOnlyRequestedListAndUnscopedSectionsVisitAll() throws {
        let bridge = CatalogBridge(), id = bridge.rows[1].objectID.uuid.uuidString
        let scoped = try bridge.sections(inList: id)
        #expect(scoped.compactMap { $0["listID"] as? String } == [id])
        #expect(bridge.enumerations == 0); #expect(bridge.sectionReads == [id])
        bridge.sectionReads = []
        #expect(try bridge.sections(inList: nil).count == 2)
        #expect(bridge.enumerations == 1)
        #expect(bridge.sectionReads == bridge.rows.map { $0.objectID.uuid.uuidString })
    }
}
