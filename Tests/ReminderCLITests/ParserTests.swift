import Testing
import Foundation
import ReminderCore
@testable import ReminderCLI

struct ParserTests {
    func command(_ args: [String]) throws -> Command {
        guard case .worker(.operation(let command)) = try CLIParser.parse(args).request else {
            throw CLIParser.invalid("Test expected operation")
        }
        return command
    }
    @Test func creationWithComplexTypedFields() throws {
        let args = ["add", "Trip", "--list", "Inbox", "--fields-json", #"{"due":{"kind":"date","value":{"year":2030,"month":2,"day":3}},"start":{"kind":"localDateTime","value":{"year":2030,"month":2,"day":2},"hour":9,"minute":30,"second":0},"recurrence":{"frequency":"monthly","interval":2,"weekdays":[{"day":2,"ordinal":1}],"monthDays":[],"months":[],"end":{"kind":"count","value":4}},"earlyAlerts":[{"before":1,"unit":"days"}],"location":{"kind":"place","title":"Station","latitude":31.2,"longitude":121.5,"radius":100,"when":"arriving"},"contact":{"phones":["+123456"],"emails":[]},"priority":"high","tags":["travel"],"parent":"parent","section":"section","position":{"kind":"after","value":"neighbor"},"assignee":"me","url":"https://example.com","flagged":true}"#]
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
        #expect(try command(["add", "Child", "--fields-json", #"{"parent":"P"}"#]) == .create(ReminderDraft(fields: ReminderFields(title: "Child", listID: "", parentID: "P"))))
    }
    @Test func patchPreservesAbsentSetAndClear() throws {
        guard case .update(let id, let version, let patch) = try command([
            "edit", "id", "--version", "v1", "--set-json", #"{"flagged":false,"tags":[],"notes":""}"#,
            "--clear", "due,location,assignee"
        ]) else { throw CLIParser.invalid("Expected update") }
        #expect(id == "id"); #expect(version == "v1")
        #expect(patch.flagged == .set(false)); #expect(patch.notes == .set(""))
        #expect(patch.tags == .set([])); #expect(patch.due == .clear)
        #expect(patch.location == .clear); #expect(patch.assigneeID == .clear)
        #expect(patch.title == .absent)
    }
    @Test func queryAndSmartFilters() throws {
        guard case .find(let query) = try command(["find", "--query-json", #"{"text":"coffee","matching":"prefix","tags":["work","home"],"excludeTags":["blocked"],"tagMatch":"any","includeCompleted":true,"completed":true,"flagged":false,"repeating":true,"hasLocation":true,"hasDueDate":false,"offset":4}"#, "--limit", "12"]) else { throw CLIParser.invalid("Expected find") }
        #expect(query.limit == 12); #expect(query.flagged == false); #expect(query.includeCompleted); #expect(query.completed == true)
        #expect(query.matching == .prefix); #expect(query.offset == 4); #expect(query.hasDueDate == false)
        #expect(query.text == "coffee"); #expect(query.tags == ["work", "home"]); #expect(query.excludeTags == ["blocked"]); #expect(query.tagMatch == .any)
        let flags = ["find", "--text", "coffee", "--matching", "prefix", "--tags-json", #"["work","home"]"#, "--exclude-tags-json", #"["blocked"]"#, "--tag-match", "any", "--include-completed", "--completed", "true", "--flagged", "false", "--repeating", "true", "--has-location", "true", "--has-due-date", "false", "--offset", "4", "--limit", "12"]
        #expect(try command(flags) == .find(query))
        for args in [["find", "--text", "coffee", "--query-json", #"{"text":"coffee"}"#], ["find", "--query-json", #"{"text":"coffee"}"#, "--text", "coffee"], ["find", "--query-json", #"{"scope":"title"}"#], ["find", "--query-json", #"{"query":{}}"#], ["find", "--flagged", "no"], ["find", "--offset", "-1"]] {
            do { _ = try command(args); Issue.record("Expected invalid input") }
            catch let error as Failure { #expect(error.code == .invalidInput) }
        }
        let filters: [SmartFilter] = [.tags(["work"], match: .all), .date(.relative(past: 0, future: 7, unit: .days)), .priorities([.high]), .flagged(true), .lists(["L"]), .location(.gettingInCar)]
        let text = #"[{"kind":"tags","value":["work"],"match":"all"},{"kind":"date","value":{"kind":"relative","past":0,"future":7,"unit":"days"}},{"kind":"priorities","value":["high"]},{"kind":"flagged","value":true},{"kind":"lists","value":["L"]},{"kind":"location","value":"gettingInCar"}]"#
        guard case .smartList(.create(let smart)) = try command(["smart-lists", "add", "Today", "--fields-json", "{\"filters\":\(text)}"]) else { throw CLIParser.invalid("Expected smart list") }
        #expect(smart.filters == filters); #expect(smart.name == "Today"); #expect(smart.match == .all)
        var rename = SmartListPatch(); rename.name = "Renamed"
        #expect(try command(["smart-lists", "edit", "S", "--set-json", #"{"name":"Renamed"}"#, "--clear", "color,icon"]) == .smartList(.update("S", rename, clear: [.color, .icon])))
    }
    @Test func containerActionsAndRequiredConfirmation() throws {
        let samples: [[String]] = [
            ["lists"], ["lists", "add", "Inbox"],
            ["lists", "edit", "L", "--set-json", #"{"name":"New","pinned":true,"kind":"groceries","sort":"title"}"#],
            ["lists", "edit", "L", "--set-json", #"{"name":"Renamed"}"#], ["lists", "edit", "L", "--clear", "icon,group"],
            ["lists", "delete", "L", "--yes"], ["lists", "clear-completed", "L", "--yes"],
            ["groups"], ["groups", "add", "Work"], ["groups", "edit", "G", "--set-json", #"{"name":"New"}"#], ["groups", "delete", "G", "--yes"],
            ["sections", "--list", "L"], ["sections", "add", "A", "--list", "L"],
            ["sections", "edit", "S", "--list", "L", "--set-json", #"{"name":"B","position":{"kind":"before","value":"other"}}"#],
            ["sections", "delete", "S", "--list", "L", "--yes"],
            ["tags"], ["tags", "edit", "old", "--set-json", #"{"name":"new"}"#], ["tags", "delete", "old", "--yes"],
            ["smart-lists"], ["smart-lists", "add", "A", "--fields-json", #"{"filters":[{"kind":"flagged","value":true}]}"#],
            ["smart-lists", "edit", "S", "--set-json", #"{"match":"any"}"#],
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
    @Test func sectionEditParsesSparseNameOrderAndCombinedChanges() throws {
        #expect(try command(["sections", "edit", "S", "--list", "L", "--set-json", #"{"name":"B"}"#]) == .section(.update(list: "L", section: "S", patch: SectionPatch(name: "B"))))
        #expect(try command(["sections", "edit", "S", "--list", "L", "--set-json", #"{"position":{"kind":"before","value":"A"}}"#]) == .section(.update(list: "L", section: "S", patch: SectionPatch(position: .before("A")))))
        #expect(try command(["sections", "edit", "S", "--list", "L", "--set-json", #"{"name":"B","position":{"kind":"after","value":"A"}}"#]) == .section(.update(list: "L", section: "S", patch: SectionPatch(name: "B", position: .after("A")))))
        #expect(throws: Failure.self) { try command(["sections", "edit", "S", "--set-json", #"{"name":"B"}"#]) }
        #expect(throws: Failure.self) { try command(["sections", "edit", "S", "--list", "L", "--set-json", "{}"]) }
    }
    @Test func reminderActionsAndLiteralArguments() throws {
        #expect(try command(["show", "--", "--json"]) == .show("--json"))
        #expect(try command(["done", "id", "--version", "v"]) == .complete(id: "id", version: "v", completed: true))
        #expect(try command(["done", "id", "--version", "v", "--undo"]) == .complete(id: "id", version: "v", completed: false))
        #expect(try command(["delete", "id", "--version", "v"]) == .delete(id: "id", version: "v"))
        #expect(try command(["restore", "id", "--list", "L"]) == .restore(id: "id", list: "L"))
        #expect(try command(["deleted"]) == .deleted)
        for scope in CatalogScope.allCases {
            let family = scope == .smartLists ? "smart-lists" : scope.rawValue
            #expect(try command([family]) == .catalog(scope))
        }
        #expect(try command(["sections", "--list", "A:B"]) == .catalog(.sections, list: "A:B"))
        #expect(try command(["image", "id", "image"]) == .image(reminderID: "id", imageID: "image"))
        #expect(try CLIParser.parse(["--json", "doctor"]) == Invocation(request: .worker(.doctor), json: true))
        #expect(try CLIParser.parse(["setup"]).request == .worker(.setup))
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
        guard case .worker(.operation(.create(let draft))) = invocation.request else { throw CLIParser.invalid("Expected create") }
        #expect(paths == ["/private/photo.png"])
        #expect(draft.images == [ImageInput(fileName: "photo.png", contentType: "image/png", bytes: Data([1, 2, 3]))])
        let encoded = String(decoding: try JSONEncoder().encode(draft), as: UTF8.self)
        #expect(!encoded.contains("/private/"))
    }
}
