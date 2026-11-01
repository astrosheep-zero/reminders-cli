import Foundation
import ObjectiveC
import Testing
import ReminderKitShim

private final class SectionIdentity: NSObject {
    @objc let uuid = NSUUID()
}

private final class SectionObject: NSObject {
    @objc let objectID = SectionIdentity()
    @objc var listID: SectionIdentity?
    @objc var parentReminderID: SectionIdentity?
    @objc var isCompleted = false
}

private final class OrderedList: NSObject {
    @objc var reminderIDsOrdering: [SectionIdentity] = []
    @objc let isGroup = false
}

private final class PositionBridge: RNBridge {
    let orderedList = OrderedList()
    var rows: [String: SectionObject] = [:]
    @objc(list:) func list(_ id: String) -> AnyObject { orderedList }
    @objc(rawReminder:concealed:) func raw(_ id: String, concealed: Bool) -> AnyObject? { rows[id] }
}

private final class SectionView: NSObject {
    var section: SectionObject?
    var failure: NSError?
    var reads = 0
    var sections: [String: SectionObject] = [:]
    @objc(fetchListSectionWithReminderID:error:)
    func fetch(_ identifier: AnyObject, error: AutoreleasingUnsafeMutablePointer<NSError?>?) -> AnyObject? {
        reads += 1
        error?.pointee = failure
        return sections[(identifier as! SectionIdentity).uuid.uuidString] ?? section
    }
}

@Suite("Native section lookup (no store)")
struct NativeSectionTests {
    /// Exercise the production helper inside its actual guard, replacing only
    /// the section-view edge. RNBridge() does not open or construct a REMStore.
    private func lookup(_ view: SectionView) -> (AnyObject?, NSError?) {
        let bridge = RNBridge(), reminder = SectionObject()
        bridge.setValue(view, forKey: "_sectionView")
        let selector = NSSelectorFromString("sectionIDForReminder:")
        typealias Lookup = @convention(c) (AnyObject, Selector, AnyObject) -> AnyObject?
        let lookup = unsafeBitCast(bridge.method(for: selector), to: Lookup.self)
        let body: @convention(block) () -> AnyObject? = {
            lookup(bridge, selector, reminder) ?? NSNull()
        }
        typealias Guard = @convention(c) (AnyObject, Selector, @convention(block) () -> AnyObject?, AutoreleasingUnsafeMutablePointer<NSError?>) -> AnyObject?
        let guardSelector = NSSelectorFromString("guard:error:")
        let guardCall = unsafeBitCast(bridge.method(for: guardSelector), to: Guard.self)
        var error: NSError?
        let result = guardCall(bridge, guardSelector, body, &error)
        return (result, error)
    }

    @Test func positionsBuildOncePerListAndCacheMissingSectionsOnlyWithinRead() {
        let bridge = PositionBridge(), view = SectionView(), list = SectionIdentity(), parent = SectionObject(), section = SectionObject()
        parent.listID = list; bridge.rows[parent.objectID.uuid.uuidString] = parent
        let rows = (0..<24).map { _ in SectionObject() }
        for (index, row) in rows.enumerated() {
            row.listID = list
            if index % 3 == 1 { row.parentReminderID = parent.objectID }
            if index % 3 == 2 { view.sections[row.objectID.uuid.uuidString] = section }
            bridge.rows[row.objectID.uuid.uuidString] = row
        }
        bridge.orderedList.reminderIDsOrdering = rows.map(\.objectID)
        bridge.setValue(view, forKey: "_sectionView")
        let selector = NSSelectorFromString("positionForReminder:")
        typealias Position = @convention(c) (AnyObject, Selector, AnyObject) -> NSDictionary?
        let position = unsafeBitCast(bridge.method(for: selector), to: Position.self)
        typealias Guard = @convention(c) (AnyObject, Selector, @convention(block) () -> AnyObject?, AutoreleasingUnsafeMutablePointer<NSError?>) -> AnyObject?
        let guardSelector = NSSelectorFromString("guard:error:")
        let guardCall = unsafeBitCast(bridge.method(for: guardSelector), to: Guard.self)
        for pass in 1...2 {
            let body: @convention(block) () -> AnyObject? = {
                for (index, row) in rows.enumerated() {
                    let value = position(bridge, selector, row)
                    let neighbor = index < 3 ? index + 3 : index - 3
                    #expect(value?["id"] as? String == rows[neighbor].objectID.uuid.uuidString)
                    #expect(value?["after"] as? Bool == (index >= 3))
                    if index == 0 { #expect(view.reads == rows.count * (pass - 1) + 4) }
                }
                return NSNumber(value: true)
            }
            var error: NSError?
            #expect(guardCall(bridge, guardSelector, body, &error) != nil)
            #expect(error == nil)
            #expect(view.reads == rows.count * pass)
        }
    }

    @Test func absentSectionWithNoErrorOrExactNativeError() {
        let view = SectionView()
        for failure in [nil, NSError(domain: "com.apple.reminderkit", code: -3009)] {
            view.failure = failure
            let (result, error) = lookup(view)
            #expect(result is NSNull)
            #expect(error == nil)
        }
    }

    @Test func validSectionReturnsItsIdentity() {
        let view = SectionView(), section = SectionObject()
        view.section = section
        let (result, error) = lookup(view)
        #expect(result as? String == section.objectID.uuid.uuidString)
        #expect(error == nil)
    }

    @Test func otherErrorsAndContradictorySectionRemainFailures() {
        let view = SectionView()
        for (domain, code, section) in [
            ("other.domain", -3009, nil),
            ("com.apple.reminderkit", -3008, nil),
            ("com.apple.reminderkit", -3009, SectionObject()),
        ] as [(String, Int, SectionObject?)] {
            view.section = section
            view.failure = NSError(domain: domain, code: code, userInfo: [NSLocalizedDescriptionKey: "Section fetch failed"])
            let (result, error) = lookup(view)
            #expect(result == nil)
            #expect(error?.domain == RNErrorDomain)
            #expect(error?.code == 2)
            #expect(error?.localizedDescription == "Section fetch failed")
        }
    }
}
