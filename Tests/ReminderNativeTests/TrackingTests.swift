import Foundation
import ObjectiveC
import Testing
import ReminderKitShim

/// Only the request/save edge is synthetic. Identities and tracked containers are
/// real ReminderKit objects; loading their classes never constructs a REMStore.
private final class TrackedChange: NSObject {
    @objc let objectID: AnyObject?
    init(_ objectID: AnyObject?) { self.objectID = objectID }
}

private final class TrackingRequest: NSObject {
    @objc var trackedReminderChangeItems: Any = NSDictionary()
    var afterSave: (() -> Void)?
    var saved = true
    var saveCalls = 0
    @objc(saveSynchronouslyWithError:)
    func save(_ error: AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool {
        saveCalls += 1
        afterSave?()
        return saved
    }
}

@Suite("Native request-owned identity tracking (no store)")
struct NativeTrackingTests {
    private let a = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    private let b = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
    private let c = "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"

    private func load() throws {
        try Bundle(path: "/System/Library/PrivateFrameworks/ReminderKit.framework")!.loadAndReturnError()
    }
    private func container(_ identifier: String, template: Bool = false) throws -> (NSObject, TrackedChange) {
        try load()
        let reminder = try #require(NSClassFromString("REMReminder") as? NSObject.Type)
        let objectID = try #require(reminder.perform(NSSelectorFromString("objectIDWithUUID:"), with: UUID(uuidString: identifier)! as NSUUID)?.takeUnretainedValue())
        let change = TrackedChange(objectID)
        return (try wrap(change, template: template), change)
    }
    private func wrap(_ change: TrackedChange, template: Bool = false) throws -> NSObject {
        let type = try #require(NSClassFromString("REMSaveRequestTrackedValueContainer") as? NSObject.Type)
        let value = type.init()
        let selector = NSSelectorFromString(template ? "setTemplate:" : "setWeakValue:")
        typealias Setter = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        let setter = unsafeBitCast(value.method(for: selector), to: Setter.self)
        setter(value, selector, change)
        return value
    }
    /// Invoke the existing private commit inside its actual operation guard. No
    /// test API is added to production and no store-backed bridge is opened.
    private func commit(_ request: TrackingRequest, bridge: RNBridge) -> NSError? {
        let selector = NSSelectorFromString("commit:")
        typealias Commit = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        let save = unsafeBitCast(bridge.method(for: selector), to: Commit.self)
        let body: @convention(block) () -> AnyObject? = {
            save(bridge, selector, request)
            return NSNumber(value: true)
        }
        typealias Guard = @convention(c) (AnyObject, Selector, @convention(block) () -> AnyObject?, AutoreleasingUnsafeMutablePointer<NSError?>) -> AnyObject?
        let guardSelector = NSSelectorFromString("guard:error:")
        let guardCall = unsafeBitCast(bridge.method(for: guardSelector), to: Guard.self)
        var error: NSError?
        _ = guardCall(bridge, guardSelector, body, &error)
        return error
    }

    @Test func installedTrackingABIPassesPreflightWithoutOpeningStore() {
        var error: NSError?
        #expect(RNPreflight([], &error))
        #expect(error == nil)
    }

    @Test func everyClosedCapabilityPassesInstalledMetadataABIWithoutOpeningStore() {
        let features = "reminder.create reminder.update reminder.delete reminder.restore title notes due start priority flagged urgent completed repeat early tags location contact url addImages removeImages assigneeID listID parentID position sectionID list.create list.update list.delete group.create group.rename group.delete section.create section.rename section.move section.delete smart.create smart.update smart.delete smart.find template.create template.use template.delete appearance".split(separator: " ").map(String.init)
        for feature in features {
            var error: NSError?
            #expect(RNPreflight([feature], &error), "\(feature): \(String(describing: error))")
        }
        var error: NSError?
        #expect(!RNPreflight(["caller-supplied-selector"], &error)); #expect(error?.code == 1)
    }

    @Test func emptyAndMultipleContainersProduceSortedDeduplicatedOwnedIDs() throws {
        let bridge = RNBridge(), request = TrackingRequest()
        #expect(commit(request, bridge: bridge) == nil)
        #expect(bridge.lastSavedReminderIDs.isEmpty)
        #expect(bridge.lastIntroducedReminderIDs.isEmpty)
        let (first, firstChange) = try container(b)
        let (second, secondChange) = try container(a, template: true)
        let (duplicate, duplicateChange) = try container(b)
        withExtendedLifetime([firstChange, secondChange, duplicateChange]) {
            request.trackedReminderChangeItems = ["one": first, "two": second, "duplicate": duplicate]
            #expect(commit(request, bridge: bridge) == nil)
            #expect(bridge.lastSavedReminderIDs == [a, b])
            #expect(bridge.lastIntroducedReminderIDs.isEmpty)
        }
    }

    @Test func introducedIDsAreOnlyNewToThisRequestDuringSave() throws {
        let bridge = RNBridge(), request = TrackingRequest()
        let (before, beforeChange) = try container(b)
        let (after, afterChange) = try container(a)
        let (introduced, introducedChange) = try container(c)
        withExtendedLifetime([beforeChange, afterChange, introducedChange]) {
            request.trackedReminderChangeItems = ["existing": before]
            request.afterSave = { request.trackedReminderChangeItems = ["new-a": after, "new-c": introduced] }
            #expect(commit(request, bridge: bridge) == nil)
            #expect(bridge.lastSavedReminderIDs == [a, b, c])
            #expect(bridge.lastIntroducedReminderIDs == [a, c])
            #expect(request.saveCalls == 1)
        }
    }

    @Test func malformedEntriesFailClosedBeforeSave() throws {
        try load()
        let type = try #require(NSClassFromString("REMSaveRequestTrackedValueContainer") as? NSObject.Type)
        let (valid, change) = try container(a)
        withExtendedLifetime(change) {
            // A direct change item is the obsolete shape, not a native container.
            for malformed: Any in [NSNull(), ["bad": change], ["valid": valid, "empty": type.init()]] {
                let bridge = RNBridge(), request = TrackingRequest()
                request.trackedReminderChangeItems = malformed
                #expect(commit(request, bridge: bridge)?.code == 2)
                #expect(request.saveCalls == 0)
                #expect(bridge.lastSavedReminderIDs.isEmpty)
            }
        }
    }

    @Test func malformedIdentityDoesNotProducePartialReceipt() throws {
        let (valid, change) = try container(a)
        let missingID = TrackedChange(nil), invalidID = TrackedChange(NSNull())
        let malformed = try [wrap(missingID), wrap(invalidID)]
        withExtendedLifetime([change, missingID, invalidID]) {
            for value in malformed {
                let bridge = RNBridge(), request = TrackingRequest()
                request.trackedReminderChangeItems = ["valid": valid, "malformed": value]
                #expect(commit(request, bridge: bridge) != nil)
                #expect(request.saveCalls == 0)
                #expect(bridge.lastSavedReminderIDs.isEmpty)
            }
        }
    }

    @Test func failedSaveAndMalformedPostSaveRetainKnownIDsAndUnknownOutcome() throws {
        let (valid, change) = try container(b)
        withExtendedLifetime(change) {
            for malformedAfter in [false, true] {
                let bridge = RNBridge(), request = TrackingRequest()
                request.trackedReminderChangeItems = ["existing": valid]
                request.saved = malformedAfter
                if malformedAfter { request.afterSave = { request.trackedReminderChangeItems = ["bad": NSNull()] } }
                let error = commit(request, bridge: bridge)
                #expect(error?.code == 5)
                #expect(error?.userInfo["affectedIDs"] as? [String] == [b])
                #expect(bridge.lastSavedReminderIDs == [b])
                #expect(bridge.lastIntroducedReminderIDs.isEmpty)
                #expect(request.saveCalls == 1)
            }
        }
    }
}
