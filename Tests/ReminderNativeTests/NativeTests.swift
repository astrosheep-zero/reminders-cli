import Foundation
import Testing
import ImageIO
import UniformTypeIdentifiers
import ReminderCore
import ReminderKitShim
@testable import ReminderNative

@Suite("ReminderNative offline translations and boundaries")
struct ReminderNativeTests {
    private let id = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    private let listID = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
    private func fixture() -> [String: Any] {
        ["id": id, "listID": listID, "title": "offline", "priority": 0, "flagged": false,
         "completed": false, "urgent": false, "tags": [String](), "early": [[Int]](),
         "urls": [String](), "images": [[String: Any]](), "childIDs": [String]()]
    }
    private func failure(_ code: ErrorCode, _ body: () throws -> Void) {
        do { try body(); Issue.record("Expected \(code.rawValue)") }
        catch let error as Failure { #expect(error.code == code) }
        catch { Issue.record("Unexpected error: \(error)") }
    }
    @Test func civilDatesDoNotBecomeMidnightInstants() throws {
        let day = ReminderDate.date(CalendarDate(2028, 2, 29))
        let components = Translation.components(day)
        #expect(components.hour == nil)
        #expect(components.timeZone == nil)
        #expect(try Translation.date(components) == day)
        let local = ReminderDate.localDateTime(CalendarDate(2026, 11, 1), hour: 1, minute: 30, second: 12)
        #expect(try Translation.date(Translation.components(local)) == local)
        failure(.unsupported) { _ = try Translation.date(DateComponents(hour: 9)) }
    }
    @Test func recurrenceUsesCheckedNativeEnums() throws {
        let rule = Recurrence(frequency: .monthly, interval: 2, weekdays: [RecurrenceDay(.friday, ordinal: -1)], months: [3, 9], end: .count(8))
        #expect(try Translation.recurrence(Translation.recurrence(rule)) == rule)
        let hourly = Recurrence(frequency: .hourly)
        #expect(try Translation.recurrence(hourly)["frequency"] as? Int == 4)
        #expect(try Translation.recurrence(Translation.recurrence(hourly)) == hourly)
        failure(.unsupported) { _ = try Translation.recurrence(["frequency": 99, "interval": 1, "weekdays": [[Int]]()]) }
        failure(.unsupported) { _ = try Translation.recurrence(["frequency": 0, "interval": 1, "weekdays": [[Int]](), "weeksOfTheYear": [2]]) }
    }
    @Test func sparsePatchesPreserveIntentAndClearing() throws {
        #expect(try Translation.patch(ReminderPatch()).isEmpty)
        var patch = ReminderPatch(); patch.title = .set("same value")
        #expect(try Translation.patch(patch).keys.sorted() == ["title"])
        #expect(try Translation.patch(patch)["title"] as? String == "same value")
        patch = ReminderPatch(); patch.notes = .clear; patch.due = .clear
        patch.earlyAlerts = .clear; patch.tags = .clear; patch.flagged = .clear
        let raw = try Translation.patch(patch)
        #expect(raw["notes"] is NSNull)
        #expect(raw["due"] is NSNull)
        #expect(raw["early"] as? [[Int]] == [])
        #expect(raw["tags"] as? [String] == [])
        #expect(raw["flagged"] as? Bool == false)
        #expect(raw["repeat"] == nil)
        patch.position = .clear
        failure(.unsupported) { _ = try Translation.patch(patch) }
    }
    @Test func earlyAlertsHaveNativeNegativeDeltas() throws {
        var patch = ReminderPatch(); patch.earlyAlerts = .set([EarlyAlert(before: 15, unit: .minutes), EarlyAlert(before: 2, unit: .weeks)])
        #expect(try Translation.patch(patch)["early"] as? [[Int]] == [[0, -15], [3, -2]])
        var raw = fixture(); raw["early"] = [[0, -15], [3, -2]]
        #expect(try Translation.reminder(raw).fields.earlyAlerts == [EarlyAlert(before: 15, unit: .minutes), EarlyAlert(before: 2, unit: .weeks)])
        raw["early"] = [[5, -1]]
        failure(.unsupported) { _ = try Translation.reminder(raw) }
    }
    @Test func readAbsenceIsNotFailureOrEmpty() throws {
        #expect(try Translation.object(NSNull()) == nil)
        failure(.backend) { _ = try Translation.object(nil) }
        failure(.backend) { _ = try Translation.object([1, 2]) }
        #expect(try Translation.reminder(fixture()).images.isEmpty)
        var incomplete = fixture(); incomplete.removeValue(forKey: "early")
        failure(.backend) { _ = try Translation.reminder(incomplete) }
    }
    @Test func optionalNativeFieldsAndUnknownEnumsAreNotFabricated() throws {
        var raw = fixture(); raw["priority"] = 12
        failure(.unsupported) { _ = try Translation.reminder(raw) }
        raw = fixture(); raw["urls"] = ["https://example.invalid/a", "https://example.invalid/b"]
        failure(.unsupported) { _ = try Translation.reminder(raw) }
        #expect(try Translation.location(["vehicle": 1]) == .gettingInCar)
        #expect(try Translation.location(["vehicle": 2]) == .gettingOutOfCar)
        failure(.unsupported) { _ = try Translation.location(["vehicle": 0]) }
    }
    @Test func imageMetadataHashesBytesNotTimestamps() throws {
        var raw = fixture()
        raw["images"] = [["id": id, "fileName": "x.png", "type": "public.png", "data": Data([1, 2, 3])]]
        let first = try Translation.reminder(raw)
        #expect(first.images[0].byteCount == 3)
        #expect(first.images[0].contentHash == "039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81")
        raw["images"] = [["id": id, "fileName": "x.png", "type": "public.png", "data": Data([1, 2, 4])]]
        #expect(try first.version() != Translation.reminder(raw).version())
    }
    @Test func supportedSmartFiltersRoundTripThroughNativeSchema() throws {
        let smart = SmartList(id: id, name: "offline", match: .any, filters: [
            .tags(["work"], match: .all), .flagged(true), .lists([listID]), .priorities([.high]),
            .date(.range(from: CalendarDate(2026, 10, 1), before: CalendarDate(2026, 11, 1))), .location(.gettingInCar)])
        let read = try SmartFilters.decode(["id": id, "name": smart.name, "filterData": SmartFilters.data(smart)])
        #expect(try SmartFilters.data(read) == SmartFilters.data(smart))
    }
    @Test func nativeDefaultAndAndMultiListUnionArePreserved() throws {
        let data = try JSONSerialization.data(withJSONObject: ["date": ["any": ""]])
        let decoded = try SmartFilters.decode(["id": id, "name": "native default", "filterData": data])
        #expect(decoded.match == .all)
        #expect(decoded.filters == [.date(.any)])
        let multi = SmartList(id: id, name: "union", filters: [.lists([listID, id])])
        let root = try #require(JSONSerialization.jsonObject(with: SmartFilters.data(multi)) as? [String: Any])
        #expect((root["lists"] as? [String: Any])?["operation"] as? String == "or")
        #expect(try SmartFilters.decode(["id": id, "name": "union", "filterData": SmartFilters.data(multi)]).filters == multi.filters)
        let andLists = try JSONSerialization.data(withJSONObject: ["lists": ["include": [listID, id], "exclude": [], "operation": "and"]])
        let unknown = try SmartFilters.decode(["id": id, "name": "intersection", "filterData": andLists])
        guard case .unknown = unknown.filters[0] else { Issue.record("Impossible multi-list intersection was reinterpreted as union"); return }
    }
    @Test func nestedUnknownSmartFieldsRemainOpaqueAndRefuseEdits() throws {
        let original: [String: Any] = ["operation": "and", "hashtags": ["hashtags": ["include": ["x"], "exclude": [], "operation": "and", "future": true]], "newFilter": ["meaning": 42]]
        let data = try JSONSerialization.data(withJSONObject: original)
        let read = try SmartFilters.decode(["id": id, "name": "unknown", "filterData": data])
        #expect(read.filters.count == 2)
        for filter in read.filters {
            guard case .unknown(let key, let payload) = filter else { Issue.record("Partially known filter was reinterpreted"); continue }
            let expected = try JSONSerialization.data(withJSONObject: original[key]!, options: [.sortedKeys, .fragmentsAllowed])
            #expect(payload == expected)
        }
        failure(.unsupported) { _ = try SmartFilters.data(read) }
    }
    @Test func unsupportedSmartFilterIsRefusedBeforeStoreConstruction() throws {
        var opened = false
        let backend = NativeReminderBackend(openBridge: { opened = true; throw Failure(.backend, "test factory must stay closed") }, permission: { "fullAccess" })
        let smart = SmartList(id: "", name: "unsupported", filters: [.time(fromHour: 2, fromMinute: 0, toHour: 4, toMinute: 0)])
        failure(.unsupported) { try backend.checkSupport(for: .smartList(.create(smart))) }
        var patch = ReminderPatch(); patch.title = .set("new")
        try backend.checkSupport(for: .update(id: id, version: "offline", patch: patch))
        #expect(!opened)
    }
    @Test func permissionRefusalDoesNotOpenStoreAndConstructionIsLazy() throws {
        var opened = false
        let backend = NativeReminderBackend(openBridge: { opened = true; throw Failure(.backend, "unexpected open") }, permission: { "denied" })
        #expect(!opened)
        failure(.permission) { _ = try backend.reminder(id: id) }
        #expect(!opened)
        #expect(try backend.reminder(id: "not a UUID; let Core resolve a title") == nil)
    }
    @Test func factoryFailureIsNotAnEmptyCatalog() {
        let backend = NativeReminderBackend(openBridge: { throw Failure(.unsupported, "injected missing framework") }, permission: { "fullAccess" })
        failure(.unsupported) { _ = try backend.catalog(includeTags: false) }
    }
    @Test func objcExceptionFenceCatchesWithoutLoadingReminderKit() {
        var error: NSError?
        let result = RNGuard({
            NSException(name: .invalidArgumentException, reason: "offline exception", userInfo: nil).raise()
            return nil
        }, &error)
        #expect(result == nil)
        #expect(error?.domain == RNErrorDomain)
        #expect(error?.code == 1)
        #expect(error?.localizedDescription == "offline exception")
        error = nil
        #expect(RNGuard({ nil }, &error) == nil)
        #expect(error?.code == 2)
        error = nil
        #expect(RNGuard({ NSNull() }, &error) is NSNull)
        #expect(error == nil)
    }
    @Test func imageValidationAndPrivateStaging() throws {
        let rgba = Data([255, 0, 0, 255])
        let provider = try #require(CGDataProvider(data: rgba as CFData))
        let image = try #require(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let bytes = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        let input = ImageInput(fileName: "../../not-a-path.png", contentType: UTType.png.identifier, bytes: bytes as Data)
        let stage = try ImageStaging([input])
        defer { try? stage.release() }
        let file = try #require(stage.images[0]["url"] as? URL)
        #expect(file.deletingLastPathComponent() == stage.directory)
        #expect(try Data(contentsOf: file) == bytes as Data)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: stage.directory.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect(directoryAttributes[.posixPermissions] as? Int == 0o700)
        #expect(fileAttributes[.posixPermissions] as? Int == 0o600)
        try stage.release()
        #expect(!FileManager.default.fileExists(atPath: stage.directory.path))
        failure(.invalidInput) { _ = try ImageStaging.validate(ImageInput(fileName: "x", contentType: "public.png", bytes: Data([0, 1, 2]))) }
        failure(.invalidInput) { _ = try ImageStaging.validate(ImageInput(fileName: "x", contentType: "public.jpeg", bytes: bytes as Data)) }
    }
    @Test func imageLeaseRequiresNewIndependentReceiptsEvenForDuplicateBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lease-\(UUID())")
        let bytes = Data([1, 2, 3]), input = ImageInput(fileName: "x.png", contentType: "public.png", bytes: Data([1, 2, 3]))
        let old: [String: Any] = ["id": "old", "sourceURL": URL(fileURLWithPath: "/tmp/persisted-old.png"), "data": bytes]
        let alias: [String: Any] = ["id": "new", "sourceURL": directory.appendingPathComponent("0.image"), "data": bytes]
        failure(.backend) { try ImageStaging.verifyConsumed([input], nativeImages: [old, alias], existingIDs: ["old"], directory: directory) }
        failure(.backend) { try ImageStaging.verifyConsumed([input], nativeImages: [old], existingIDs: ["old"], directory: directory) }
        let independent: [String: Any] = ["id": "new", "sourceURL": URL(fileURLWithPath: "/tmp/persisted-new.png"), "data": bytes]
        try ImageStaging.verifyConsumed([input], nativeImages: [old, independent], existingIDs: ["old"], directory: directory)
        failure(.backend) { try ImageStaging.verifyConsumed([input, input], nativeImages: [independent], existingIDs: [], directory: directory) }
    }
    @Test func fullCoreColorPaletteIsMappedBeforeNativeCalls() throws {
        for name in ["red", "orange", "yellow", "green", "blue", "purple", "brown", "light-blue", "indigo", "pink", "gray", "rose"] {
            #expect(try Translation.color(name) != nil)
        }
        #expect(try Translation.color("light-blue")?["name"] as? String == "lightBlue")
        #expect(try Translation.color("cyan")?["hex"] as? String == "#5AC8FA")
        failure(.invalidInput) { _ = try Translation.color("not a native symbolic color") }
    }
}
