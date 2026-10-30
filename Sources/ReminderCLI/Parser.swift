import Foundation
import Darwin
import ReminderCore

/// This table is both the parser's allowlist and the command reference printed by --help.
struct CommandSpec {
    let name: String
    let arguments: Int
    let values: Set<String>
    let switches: Set<String>
    let required: Set<String>
    let summary: String
    init(_ name: String, _ arguments: Int = 0, values: String = "", switches: String = "",
         required: String = "", _ summary: String) {
        self.name = name; self.arguments = arguments
        self.values = Set(values.split(separator: " ").map(String.init))
        self.switches = Set(switches.split(separator: " ").map(String.init))
        self.required = Set(required.split(separator: " ").map(String.init)); self.summary = summary
    }
    init(_ name: String, _ summary: String) { self.init(name, 0, summary) }
}

enum CLIRequest: Equatable {
    case help, setup, doctor
    case operation(Command, projection: String?)
}
struct Invocation: Equatable {
    var request: CLIRequest
    var json: Bool
}

enum CLIParser {
    static let specs: [CommandSpec] = [
        .init("find", values: "query-json text list limit", "Find reminders; --query-json supplies typed filters"),
        .init("show", 1, "Show ID or exact title, with version token"),
        .init("add", 1, values: "list fields-json image image-type", required: "list", "Create TITLE --list ID/NAME; optional typed fields"),
        .init("edit", 1, values: "version set-json clear image image-type remove-images", required: "version", "Patch ID; --set-json values, --clear comma-separated fields"),
        .init("done", 1, values: "version", switches: "undo", required: "version", "Complete ID (or --undo)"),
        .init("delete", 1, values: "version", required: "version", "Delete ID and known children to recoverable storage"),
        .init("deleted", "List only this tool's deletion journal (scope=toolOnly)"),
        .init("catalog", "Read full catalog including tag counts (enumerates reminders for tags)"),
        .init("restore", 1, values: "list", "Restore ID to journal destination or explicit --list"),
        .init("image", 2, "Read reminder ID image ID as base64 JSON"),
        .init("lists", "List lists and joined members"),
        .init("lists add", 1, values: "fields-json", "Create NAME with optional typed ListFields"),
        .init("lists edit", 1, values: "fields-json", required: "fields-json", "Replace editable list fields (full ListFields JSON required)"),
        .init("lists delete", 1, switches: "yes", required: "yes", "Delete list and contents; requires --yes"),
        .init("lists clear-completed", 1, switches: "yes", required: "yes", "Delete completed reminders; requires --yes"),
        .init("groups", "List groups"),
        .init("groups add", 1, "Create NAME"),
        .init("groups rename", 1, values: "name", required: "name", "Rename ID --name NAME"),
        .init("groups delete", 1, switches: "yes", required: "yes", "Delete group; requires --yes"),
        .init("sections", values: "list", "List sections (optionally --list ID)"),
        .init("sections add", 1, values: "list", required: "list", "Create NAME --list ID/NAME"),
        .init("sections rename", 1, values: "list name", required: "list name", "Rename ID --list LIST --name NAME"),
        .init("sections move", 1, values: "list position-json", required: "list position-json", "Move ID --position-json typed Position"),
        .init("sections delete", 1, values: "list", switches: "yes", required: "list yes", "Delete ID --list LIST --yes"),
        .init("tags", "List tags with counts"),
        .init("tags rename", 1, values: "name", required: "name", "Rename TAG --name NAME"),
        .init("tags delete", 1, switches: "yes", required: "yes", "Delete tag; requires --yes"),
        .init("smart-lists", "List smart lists, preserving opaque unknown filters"),
        .init("smart-lists add", 1, values: "definition-json", required: "definition-json", "Create NAME with typed smart-list definition"),
        .init("smart-lists edit", 1, values: "definition-json", required: "definition-json", "Replace smart-list definition"),
        .init("smart-lists delete", 1, switches: "yes", required: "yes", "Delete smart list; requires --yes"),
        .init("templates", "List templates"),
        .init("templates add", 1, values: "list", switches: "include-completed", required: "list", "Create NAME from --list LIST"),
        .init("templates use", 1, values: "name", "Instantiate template ID, optional new list --name"),
        .init("templates delete", 1, switches: "yes", required: "yes", "Delete template; requires --yes"),
        .init("setup", "Explicitly request Reminders full access (only prompting command)"),
        .init("doctor", "Inspect bundle/signature/permissions; safe read probe only when already authorized")
    ]
    static var help: String {
        """
        reminder — macOS Reminders CLI POC
        Usage: reminder COMMAND [ARGS] [OPTIONS] [--json]
        IDs or exact names; ambiguous names refuse. Use -- before dash-prefixed positional values.
        JSON arguments are inline typed JSON, never arbitrary selectors or native RPC.
        \(specs.map { "  \($0.name)\($0.arguments > 0 ? " " + Array(repeating: "ARG", count: $0.arguments).joined(separator: " ") : "")\n    \($0.summary)\n    Options: \(($0.values.map { "--\($0) VALUE" } + $0.switches.map { "--\($0)" }).sorted().joined(separator: " "))" }.joined(separator: "\n"))
        Global: --json, --help. See README.md for exact typed JSON and safety limits.
        Edit/done/delete require --version from show/find. Version checks are not atomic cross-device CAS.
        Exit: 0 ok; 1 input; 2 missing/ambiguous/conflict; 3 permission/sandbox;
              4 unsupported; 5 outcome unknown (DO NOT blindly retry); 6 backend/io/internal.
        """
    }

    static func parse(_ arguments: [String], readImage: (String) throws -> Data = readImage) throws -> Invocation {
        var args = arguments
        let globalEnd = args.firstIndex(of: "--") ?? args.count
        let json = args.prefix(globalEnd).contains("--json")
        let helpRequested = args.prefix(globalEnd).contains("--help")
        args = args.enumerated().filter { !($0.offset < globalEnd && $0.element == "--json") }.map(\.element)
        if args.isEmpty || args == ["help"] || helpRequested { return Invocation(request: .help, json: json) }
        var name = args.removeFirst()
        if ["lists", "groups", "sections", "tags", "smart-lists", "templates"].contains(name),
           let action = args.first, !action.hasPrefix("--") { name += " " + args.removeFirst() }
        guard let spec = specs.first(where: { $0.name == name }) else { throw invalid("Unknown command: \(name)") }
        var values: [String: String] = [:], flags: Set<String> = [], positional: [String] = []
        var literal = false
        while !args.isEmpty {
            let arg = args.removeFirst()
            if arg == "--", !literal { literal = true; continue }
            if !literal, arg.hasPrefix("--") {
                let key = String(arg.dropFirst(2))
                guard values[key] == nil, !flags.contains(key) else { throw invalid("Duplicate --\(key)") }
                if spec.switches.contains(key) { flags.insert(key) }
                else if spec.values.contains(key) {
                    guard let value = args.first, !value.hasPrefix("--") else { throw invalid("Missing value for --\(key)") }
                    values[key] = args.removeFirst()
                } else { throw invalid("Unknown option --\(key) for \(name)") }
            } else { positional.append(arg) }
        }
        guard positional.count == spec.arguments else { throw invalid("\(name) expects \(spec.arguments) positional arguments") }
        for argument in positional { try Validation.name(argument) }
        for key in spec.required where values[key] == nil && !flags.contains(key) { throw invalid("\(name) requires --\(key)") }
        for (key, value) in values where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw invalid("--\(key) cannot be empty")
        }
        func value(_ key: String) -> String { values[key]! }
        func op(_ command: Command, _ projection: String? = nil) -> Invocation {
            Invocation(request: .operation(command, projection: projection), json: json)
        }
        func image() throws -> [ImageInput] {
            guard let path = values["image"] else {
                if values["image-type"] != nil { throw invalid("--image-type requires --image") }; return []
            }
            guard let type = values["image-type"], type.hasPrefix("image/") else { throw invalid("--image requires --image-type image/TYPE") }
            return [ImageInput(fileName: URL(fileURLWithPath: path).lastPathComponent, contentType: type, bytes: try readImage(path))]
        }
        let first = positional.first ?? ""
        switch name {
        case "setup": return Invocation(request: .setup, json: json)
        case "doctor": return Invocation(request: .doctor, json: json)
        case "find":
            var query = try merged(ReminderQuery(), values["query-json"])
            if let text = values["text"] { query.text = text }; if let list = values["list"] { query.list = list }
            if let limit = values["limit"] {
                guard let count = Int(limit), count > 0 else { throw invalid("--limit must be positive") }; query.limit = count
            }
            return op(.find(query))
        case "show": return op(.show(first))
        case "add":
            let fields = try merged(ReminderFields(title: first, listID: value("list")), values["fields-json"])
            guard fields.title == first, fields.listID == value("list") else { throw invalid("Use positional TITLE and --list, not fields-json, for create identity") }
            let images = try image()
            try Validation.fields(fields, images: images)
            return op(.create(ReminderDraft(fields: fields, images: images)))
        case "edit":
            var patch = try patch(values["set-json"], clear: values["clear"])
            patch.addImages = try image()
            patch.removeImageIDs = values["remove-images"].map { $0.split(separator: ",").map(String.init) } ?? []
            guard patch != ReminderPatch() else { throw invalid("edit requires a change") }
            return op(.update(id: first, version: value("version"), patch: patch))
        case "done": return op(.complete(id: first, version: value("version"), completed: !flags.contains("undo")))
        case "delete": return op(.delete(id: first, version: value("version")))
        case "deleted": return op(.deleted)
        case "catalog": return op(.catalog(includeTags: true))
        case "restore": return op(.restore(id: first, list: values["list"]))
        case "image": return op(.image(reminderID: first, imageID: positional[1]))
        case "lists", "groups", "sections", "tags", "smart-lists", "templates":
            // Projection is presentation only; Core still receives the typed catalog command.
            return op(.catalog(includeTags: name == "tags"), name + (values["list"].map { ":" + $0 } ?? ""))
        case "lists add":
            let fields = try merged(ListFields(name: first), values["fields-json"])
            guard fields.name == first else { throw invalid("Use positional NAME for list creation") }
            return op(.list(.create(fields)))
        case "lists edit": return op(.list(.update(first, try decode(ListFields.self, value("fields-json")))))
        case "lists delete": return op(.list(.delete(first, confirmed: true)))
        case "lists clear-completed": return op(.list(.clearCompleted(first, confirmed: true)))
        case "groups add": return op(.group(.create(first)))
        case "groups rename": return op(.group(.rename(first, name: value("name"))))
        case "groups delete": return op(.group(.delete(first, confirmed: true)))
        case "sections add": return op(.section(.create(list: value("list"), name: first)))
        case "sections rename": return op(.section(.rename(list: value("list"), section: first, name: value("name"))))
        case "sections move": return op(.section(.move(list: value("list"), section: first, position: try decode(Position.self, value("position-json")))))
        case "sections delete": return op(.section(.delete(list: value("list"), section: first, confirmed: true)))
        case "tags rename": return op(.tag(.rename(first, name: value("name"))))
        case "tags delete": return op(.tag(.delete(first, confirmed: true)))
        case "smart-lists add":
            let definition = try merged(SmartList(id: "", name: first), values["definition-json"])
            guard definition.name == first, definition.id.isEmpty else { throw invalid("Use positional NAME; new smart-list id must be empty") }
            return op(.smartList(.create(definition)))
        case "smart-lists edit":
            return op(.smartList(.update(first, try decode(SmartList.self, value("definition-json")))))
        case "smart-lists delete": return op(.smartList(.delete(first, confirmed: true)))
        case "templates add": return op(.template(.create(name: first, list: value("list"), includeCompleted: flags.contains("include-completed"))))
        case "templates use": return op(.template(.use(first, newListName: values["name"])))
        case "templates delete": return op(.template(.delete(first, confirmed: true)))
        default: throw invalid("Unimplemented parser command")
        }
    }

    static func invalid(_ message: String) -> Failure { Failure(.invalidInput, message) }
    static func decode<T: Codable>(_ type: T.Type, _ text: String) throws -> T {
        do {
            let data = Data(text.utf8)
            let result = try JSONDecoder().decode(type, from: data)
            let input = try JSONDecoder().decode(JSONValue.self, from: data)
            let output = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(result))
            try input.checkKeys(against: output)
            return result
        } catch let error as Failure { throw error }
        catch { throw invalid("Invalid typed JSON: \(error)") }
    }
    /// Overlay a partial typed object on actual Core defaults, not a duplicate CLI schema.
    static func merged<T: Codable>(_ defaults: T, _ text: String?) throws -> T {
        guard let text else { return defaults }
        let base = try JSONValue.properties(defaults)
        let object = try jsonObject(text)
        // Optional Core properties are omitted by Codable; use the explicit field allowlists.
        let keys: Set<String>
        switch defaults {
        case is ReminderFields: keys = reminderKeys
        case is ReminderQuery: keys = queryKeys
        case is ListFields: keys = listKeys
        case is SmartList: keys = smartKeys
        default: keys = Set(base.keys)
        }
        guard Set(object.keys).isSubset(of: keys) else { throw invalid("Unknown JSON field: \(Set(object.keys).subtracting(keys).sorted())") }
        let data = try JSONEncoder().encode(JSONValue.object(base.merging(object) { _, new in new }))
        return try decode(T.self, String(decoding: data, as: UTF8.self))
    }
    static let reminderKeys: Set<String> = ["title", "listID", "notes", "due", "start", "recurrence", "earlyAlerts", "location", "contact", "url", "priority", "flagged", "urgent", "completed", "tags", "parentID", "sectionID", "position", "assigneeID"]
    static let queryKeys: Set<String> = ["text", "list", "smartList", "section", "includeCompleted", "flagged", "urgent", "repeating", "hasLocation", "assigneeID", "tags", "dueOnOrAfter", "dueBefore", "limit"]
    static let listKeys: Set<String> = ["name", "color", "icon", "groupID", "pinned", "kind", "sort", "position"]
    static let smartKeys: Set<String> = ["id", "name", "color", "icon", "match", "filters"]
    static func jsonObject(_ text: String) throws -> [String: JSONValue] {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
              case .object(let object) = value else { throw invalid("Expected JSON object") }
        return object
    }
    static func patch(_ text: String?, clear: String?) throws -> ReminderPatch {
        let sets = try text.map(jsonObject) ?? [:]
        let clears = clear.map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) } ?? []
        guard Set(sets.keys).isSubset(of: reminderKeys), Set(clears).isSubset(of: reminderKeys),
              Set(sets.keys).isDisjoint(with: clears), Set(clears).count == clears.count else {
            throw invalid("Unknown, duplicate, or conflicting set/clear fields")
        }
        var object = try JSONValue.properties(ReminderPatch())
        for (key, value) in sets {
            guard value != .null else { throw invalid("Use --clear \(key), not null, to clear a field") }
            object[key] = .object(["set": .object(["_0": value])])
        }
        for key in clears { object[key] = .object(["clear": .object([:])]) }
        return try decode(ReminderPatch.self, String(decoding: JSONEncoder().encode(JSONValue.object(object)), as: UTF8.self))
    }
    static func readImage(_ path: String) throws -> Data {
        do {
            guard !path.contains("\0") else { throw invalid("Image path contains NUL") }
            let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(handle.fileDescriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
                throw invalid("Image input must be a regular file")
            }
            let data = try handle.read(upToCount: 16 * 1024 * 1024 + 1) ?? Data()
            guard !data.isEmpty, data.count <= 16 * 1024 * 1024 else { throw invalid("Image empty or larger than 16 MiB") }
            return data
        } catch let error as Failure { throw error }
        catch { throw Failure(.io, "Cannot read image: \(error.localizedDescription)") }
    }
}
