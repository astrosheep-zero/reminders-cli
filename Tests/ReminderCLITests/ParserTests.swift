import Testing
import Foundation
import ReminderCore
@testable import ReminderCLI

struct ParserTests {
    func command(_ args: [String]) throws -> Command {
        guard case .operation(let command, _) = try CLIParser.parse(args).request else {
            throw CLIParser.invalid("Test expected operation")
        }
        return command
    }
    @Test func creationWithComplexTypedFields() throws {
        let args = ["add", "Trip", "--list", "Inbox", "--fields-json", #"{"due":{"kind":"date","value":{"year":2030,"month":2,"day":3}},"start":{"kind":"localDateTime","value":{"year":2030,"month":2,"day":2},"hour":9,"minute":30,"second":0},"recurrence":{"frequency":"monthly","interval":2,"weekdays":[{"day":2,"ordinal":1}],"monthDays":[],"months":[],"end":{"kind":"count","value":4}},"earlyAlerts":[{"before":1,"unit":"days"}],"location":{"kind":"place","title":"Station","latitude":31.2,"longitude":121.5,"radius":100,"when":"arriving"},"contact":{"phones":["+123456"],"emails":[]},"priority":"high","tags":["travel"],"parentID":"parent","sectionID":"section","position":{"kind":"after","value":"neighbor"},"assigneeID":"me","url":"https://example.com","flagged":true}"#]
        guard case .create(let draft) = try command(args) else { throw CLIParser.invalid("Expected create") }
        #expect(draft.fields.title == "Trip")
        #expect(draft.fields.due == .date(CalendarDate(2030, 2, 3)))
        #expect(draft.fields.recurrence?.weekdays == [RecurrenceDay(.monday, ordinal: 1)])
        #expect(draft.fields.earlyAlerts == [EarlyAlert(before: 1, unit: .days)])
        #expect(draft.fields.assigneeID == "me")
        #expect(draft.fields.flagged)
    }
    @Test func creationCanDeferListSelectionToCore() throws {
        #expect(try command(["add", "Title"]) == .create(ReminderDraft(fields: ReminderFields(title: "Title", listID: ""))))
        #expect(try command(["add", "Child", "--fields-json", #"{"parentID":"P"}"#]) == .create(ReminderDraft(fields: ReminderFields(title: "Child", listID: "", parentID: "P"))))
    }
    @Test func patchPreservesAbsentSetAndClear() throws {
        guard case .update(let id, let version, let patch) = try command([
            "edit", "id", "--version", "v1", "--set-json", #"{"flagged":false,"tags":[],"notes":""}"#,
            "--clear", "due,location,assigneeID"
        ]) else { throw CLIParser.invalid("Expected update") }
        #expect(id == "id"); #expect(version == "v1")
        #expect(patch.flagged == .set(false)); #expect(patch.notes == .set(""))
        #expect(patch.tags == .set([])); #expect(patch.due == .clear)
        #expect(patch.location == .clear); #expect(patch.assigneeID == .clear)
        #expect(patch.title == .absent)
    }
    @Test func queryAndSmartFilters() throws {
        guard case .find(let query) = try command(["find", "--query-json", #"{"text":"coffee","matching":"prefix","includeCompleted":true,"completed":true,"flagged":false,"repeating":true,"hasLocation":true,"hasDueDate":false,"offset":4}"#, "--limit", "12"]) else { throw CLIParser.invalid("Expected find") }
        #expect(query.limit == 12); #expect(query.flagged == false); #expect(query.includeCompleted); #expect(query.completed == true)
        #expect(query.matching == .prefix); #expect(query.offset == 4); #expect(query.hasDueDate == false)
        let filters: [SmartFilter] = [.tags(["work"], match: .all), .date(.relative(past: 0, future: 7, unit: .days)), .priorities([.high]), .flagged(true), .lists(["L"]), .location(.gettingInCar)]
        let text = #"[{"kind":"tags","value":["work"],"match":"all"},{"kind":"date","value":{"kind":"relative","past":0,"future":7,"unit":"days"}},{"kind":"priorities","value":["high"]},{"kind":"flagged","value":true},{"kind":"lists","value":["L"]},{"kind":"location","value":"gettingInCar"}]"#
        guard case .smartList(.create(let smart)) = try command(["smart-lists", "add", "Today", "--definition-json", "{\"filters\":\(text)}"]) else { throw CLIParser.invalid("Expected smart list") }
        #expect(smart.filters == filters); #expect(smart.name == "Today")
    }
    @Test func containerActionsAndRequiredConfirmation() throws {
        let samples: [[String]] = [
            ["lists"], ["lists", "add", "Inbox"],
            ["lists", "edit", "L", "--fields-json", #"{"name":"New","pinned":true,"kind":"groceries","sort":"title"}"#],
            ["lists", "delete", "L", "--yes"], ["lists", "clear-completed", "L", "--yes"],
            ["groups"], ["groups", "add", "Work"], ["groups", "rename", "G", "--name", "New"], ["groups", "delete", "G", "--yes"],
            ["sections", "--list", "L"], ["sections", "add", "A", "--list", "L"],
            ["sections", "rename", "S", "--list", "L", "--name", "B"],
            ["sections", "move", "S", "--list", "L", "--position-json", #"{"kind":"before","value":"other"}"#],
            ["sections", "delete", "S", "--list", "L", "--yes"],
            ["tags"], ["tags", "rename", "old", "--name", "new"], ["tags", "delete", "old", "--yes"],
            ["smart-lists"], ["smart-lists", "add", "A", "--definition-json", "{}"],
            ["smart-lists", "edit", "S", "--definition-json", #"{"id":"S","name":"A","match":"any","filters":[]}"#],
            ["smart-lists", "delete", "S", "--yes"], ["templates"],
            ["templates", "add", "T", "--list", "L", "--include-completed"],
            ["templates", "use", "T", "--name", "New list"], ["templates", "delete", "T", "--yes"]
        ]
        for sample in samples {
            _ = try command(sample)
            if sample.contains("--yes") {
                #expect(throws: Failure.self) { try command(sample.filter { $0 != "--yes" }) }
            }
        }
    }
    @Test func reminderActionsAndLiteralArguments() throws {
        #expect(try command(["show", "--", "--json"]) == .show("--json"))
        #expect(try command(["done", "id", "--version", "v"]) == .complete(id: "id", version: "v", completed: true))
        #expect(try command(["done", "id", "--version", "v", "--undo"]) == .complete(id: "id", version: "v", completed: false))
        #expect(try command(["delete", "id", "--version", "v"]) == .delete(id: "id", version: "v"))
        #expect(try command(["restore", "id", "--list", "L"]) == .restore(id: "id", list: "L"))
        #expect(try command(["deleted"]) == .deleted)
        #expect(try command(["catalog"]) == .catalog(includeTags: true))
        #expect(try command(["tags"]) == .catalog(includeTags: true))
        for family in ["lists", "groups", "sections", "smart-lists", "templates"] {
            #expect(try command([family]) == .catalog(includeTags: false))
        }
        #expect(try command(["image", "id", "image"]) == .image(reminderID: "id", imageID: "image"))
        #expect(try CLIParser.parse(["--json", "doctor"]) == Invocation(request: .doctor, json: true))
        #expect(try CLIParser.parse(["setup"]).request == .setup)
    }
    @Test func invalidInputsDoNotReadImageOrReachWorker() {
        let samples: [[String]] = [
            ["edit", "id"], ["done", "id"], ["delete", "id"],
            ["find", "--selector", "anything"], ["find", "--limit", "0"], ["show"],
            ["find", "--text", "x", "--text", "y"], ["edit", "id", "--version", "v"],
            ["edit", "id", "--version", "v", "--set-json", #"{"notes":null}"#],
            ["edit", "id", "--version", "v", "--set-json", #"{"notes":"x"}"#, "--clear", "notes"],
            ["edit", "id", "--version", "v", "--clear", "due,due"],
            ["add", "T", "--list", "L", "--fields-json", #"{"listID":"other"}"#],
            ["add", "T", "--list", "L", "--fields-json", #"{"unknown":1}"#],
            ["add", "T", "--list", "L", "--fields-json", #"{"priority":"critical"}"#],
            ["add", "T", "--list", "L", "--fields-json", #"{"due":{"kind":"date","value":{"year":2030,"month":2,"day":31}}}"#],
            ["add", "T", "--list", "L", "--fields-json", #"{"due":{"kind":"date","value":{"year":2030,"month":2,"day":3,"typo":2}}}"#],
            ["show", ""], ["--worker", "--json"]
        ]
        for sample in samples {
            #expect(throws: Failure.self) {
                try CLIParser.parse(sample, readImage: { _ in Issue.record("Must not read images"); return Data() })
            }
        }
    }
    @Test func imageReaderUsesBoundedRegularFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cli-image-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fixture.png")
        try Data([1, 2, 3]).write(to: file)
        #expect(try CLIParser.readImage(file.path) == Data([1, 2, 3]))
        #expect(throws: Failure.self) { try CLIParser.readImage(directory.path) }
        try Data().write(to: file)
        #expect(throws: Failure.self) { try CLIParser.readImage(file.path) }
    }
    @Test func imageBytesAreReadInFrontend() throws {
        var paths: [String] = []
        let invocation = try CLIParser.parse(["add", "T", "--list", "L", "--image", "/private/photo.png", "--image-type", "image/png"], readImage: { path in paths.append(path); return Data([1, 2, 3]) })
        guard case .operation(.create(let draft), _) = invocation.request else { throw CLIParser.invalid("Expected create") }
        #expect(paths == ["/private/photo.png"])
        #expect(draft.images == [ImageInput(fileName: "photo.png", contentType: "image/png", bytes: Data([1, 2, 3]))])
        let encoded = String(decoding: try JSONEncoder().encode(draft), as: UTF8.self)
        #expect(!encoded.contains("/private/"))
    }
}
