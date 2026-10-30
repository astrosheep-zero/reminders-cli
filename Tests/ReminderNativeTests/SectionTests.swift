import Foundation
import ObjectiveC
import Testing
import ReminderKitShim

private final class SectionIdentity: NSObject {
    @objc let uuid = NSUUID()
}

private final class SectionObject: NSObject {
    @objc let objectID = SectionIdentity()
}

private final class SectionView: NSObject {
    var section: SectionObject?
    var failure: NSError?
    @objc(fetchListSectionWithReminderID:error:)
    func fetch(_ identifier: AnyObject, error: AutoreleasingUnsafeMutablePointer<NSError?>?) -> AnyObject? {
        error?.pointee = failure
        return section
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
