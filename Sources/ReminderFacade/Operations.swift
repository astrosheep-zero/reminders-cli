import Foundation
import ReminderCore

public struct OperationDefinition: Sendable {
    public let name: String
    public let positional: [String]
    public let summary: String
    let fields: [String: Schema]
    let required: Set<String>
    let dispatch: @Sendable (Arguments) throws -> PreparedOperation
    public var toolName: String { name.replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_") }
    public var inputSchema: JSONValue { Schema.object(fields, required: required).json }
    public var readOnly: Bool { !name.contains(" ") && !["add", "edit", "done", "delete", "restore", "deleted"].contains(name) }
    public var destructive: Bool { name.contains("delete") || name.contains("clear-completed") || ["edit", "done"].contains(name) }
    init(_ name: String, _ positional: String = "", _ fields: [String: Schema] = [:], required: String = "", _ summary: String,
         dispatch: @escaping @Sendable (Arguments) throws -> PreparedOperation) {
        self.name = name; self.positional = positional.split(separator: " ").map(String.init)
        self.fields = fields; self.required = Set(required.split(separator: " ").map(String.init)).union(self.positional)
        self.summary = summary; self.dispatch = dispatch
    }
    /// CLI names adapt the same parameters; no separate command allowlist or dispatch switch.
    public var options: [String: String] {
        var result = Dictionary(uniqueKeysWithValues: fields.keys.filter { !positional.contains($0) && $0 != "images" }.map { key in
            let option = ["query": "query-json", "fields": "fields-json", "set": "set-json", "definition": "definition-json",
                "position": "position-json", "confirmed": "yes", "includeCompleted": "include-completed", "removeImageIDs": "remove-images"][key] ?? key
            return (option, key)
        })
        if fields["images"] != nil { result["image"] = "image"; result["image-type"] = "image-type" }
        return result
    }
    public func isSwitch(_ key: String) -> Bool { if case .scalar("boolean", _) = fields[key] { true } else { false } }
}

public struct PreparedOperation: Sendable, Equatable {
    public var request: WorkerRequest
    public var projection: String?
    public init(_ command: Command, projection: String? = nil) { self.init(request: .operation(command), projection: projection) }
    public init(request: WorkerRequest, projection: String? = nil) { self.request = request; self.projection = projection }
}
struct Arguments {
    let values: [String: JSONValue]
    func text(_ key: String) -> String? { if case .string(let value) = values[key] { value } else { nil } }
    func string(_ key: String) -> String { text(key) ?? "" }
    func bool(_ key: String) -> Bool { values[key] == .bool(true) }
    var id: String { string("id") }
    var name: String { string("name") }
    var list: String { string("list") }
    var version: String { string("version") }
    func decode<T: Decodable>(_ type: T.Type, _ key: String) throws -> T {
        do { return try JSONDecoder().decode(type, from: JSONEncoder().encode(values[key] ?? .null)) }
        catch { throw invalid("Invalid \(key): \(error)") }
    }
    func merged<T: Codable>(_ defaults: T, _ key: String) throws -> T {
        guard case .object(let object) = values[key] else { return defaults }
        return try Arguments(values: [key: .object(JSONValue.properties(defaults).merging(object) { _, new in new })]).decode(T.self, key)
    }
    func patch() throws -> ReminderPatch {
        let sets: [String: JSONValue] = values["set"].flatMap { if case .object(let object) = $0 { object } else { nil } } ?? [:]
        let clears = try values["clear"].map { _ in try decode([String].self, "clear") } ?? []
        guard Set(sets.keys).isDisjoint(with: clears), Set(clears).count == clears.count else { throw invalid("Duplicate or conflicting set/clear fields") }
        var object = sets.mapValues { JSONValue.object(["set": .object(["_0": $0])]) }
        for key in clears { object[key] = .object(["clear": .object([:])]) }
        object["addImages"] = values["images"]; object["removeImageIDs"] = values["removeImageIDs"]
        let patch = try Arguments(values: ["patch": .object(object)]).decode(ReminderPatch.self, "patch")
        guard patch != ReminderPatch() else { throw invalid("edit requires a change") }; return patch
    }
}

public enum FacadeOperations {
    public static let definitions: [OperationDefinition] = [
        .init("doctor", "", [:], "Inspect bundle/signature/authorization. Sentinel read only if already authorized; never prompts. A diagnostic report is not proof every check passed.") { _ in .init(request: .doctor) },
        .init("find", "", ["query": Shapes.query, "text": .string, "list": .string, "limit": .int], "Find using native criteria or a smart list. completed overrides includeCompleted for ordinary queries. Default excludes completed; limit 100, offset 0.") { a in
            var query = try a.merged(ReminderQuery(), "query")
            if let text = a.text("text") { query.text = text }; if let list = a.text("list") { query.list = list }
            if a.values["limit"] != nil { query.limit = try a.decode(Int.self, "limit") }
            try Validation.query(query); return .init(.find(query))
        },
        .init("show", "id", ["id": .string], "Show ID or native title-equals match, including an optimistic version token.") { .init(.show($0.id)) },
        .init("add", "title", ["title": .string, "list": .string, "fields": Shapes.fields, "images": Shapes.images], "Create a reminder in the supplied list, parent's list or unique default list. Images are base64 bytes, never worker paths.") { a in
            let fields = try a.merged(ReminderFields(title: a.string("title"), listID: a.list), "fields")
            guard fields.title == a.string("title"), a.text("list") == nil || fields.listID == a.list else { throw invalid("Conflicting create title/list identity") }
            let images = try a.values["images"].map { _ in try a.decode([ImageInput].self, "images") } ?? []
            try Validation.fields(fields, images: images, listRequired: false); return .init(.create(ReminderDraft(fields: fields, images: images)))
        },
        .init("edit", "id", ["id": .string, "version": .string, "set": Shapes.fields, "clear": .array(.choice(Shapes.reminderFields.keys.sorted().joined(separator: " "))), "images": Shapes.images, "removeImageIDs": .array(.string)], required: "version", "Sparse edit: omitted fields stay unchanged; set values or explicitly clear. Requires latest version; not atomic cross-device CAS.") { try .init(.update(id: $0.id, version: $0.version, patch: $0.patch())) },
        .init("done", "id", ["id": .string, "version": .string, "undo": .bool], required: "version", "Complete reminder; undo=true marks incomplete. Requires version.") { .init(.complete(id: $0.id, version: $0.version, completed: !$0.bool("undo"))) },
        .init("delete", "id", ["id": .string, "version": .string], required: "version", "Soft-delete reminder and known children with journal evidence. Requires version; no purge.") { .init(.delete(id: $0.id, version: $0.version)) },
        .init("deleted", "", [:], "Reconcile this tool's deletion journal only (toolOnly), not system Recently Deleted.") { _ in .init(.deleted) },
        .init("catalog", "", [:], "Read all catalog families including native tag selections and counts.") { _ in .init(.catalog(includeTags: true)) },
        .init("restore", "id", ["id": .string, "list": .string], "Restore root/children to saved destination or explicit list. Never retries uncertain saves.") { .init(.restore(id: $0.id, list: $0.text("list"))) },
        .init("image", "id imageID", ["id": .string, "imageID": .string], "Explicit image bytes read, returned as base64. May fail with native permission error; no prompt or invented permission fix.") { .init(.image(reminderID: $0.id, imageID: $0.string("imageID"))) },
        .init("lists", "", [:], "Read list metadata, default marker and already-joined members; no invitations.") { _ in .init(.catalog(includeTags: false), projection: "lists") },
        .init("lists add", "name", ["name": .string, "fields": Shapes.list], "Create list with optional appearance, grouping and sorting fields.") { a in
            let fields = try a.merged(ListFields(name: a.name), "fields")
            guard fields.name == a.name else { throw invalid("Use name for list creation identity") }; return .init(.list(.create(fields)))
        },
        .init("lists edit", "id", ["id": .string, "fields": Shapes.list.requiring("name pinned kind sort")], required: "fields", "Full list replacement: name/pinned/kind/sort required; omitted optional fields clear. Position omission means no ordering request.") { try .init(.list(.update($0.id, $0.decode(ListFields.self, "fields")))) },
        .init("lists delete", "id", ["id": .string, "confirmed": .bool], required: "confirmed", "Delete list and contents; confirmed must be true. Journals selected reminders first.") { .init(.list(.delete($0.id, confirmed: true))) },
        .init("lists clear-completed", "id", ["id": .string, "confirmed": .bool], required: "confirmed", "Soft-delete completed reminders and selected parents' children; confirmed must be true.") { .init(.list(.clearCompleted($0.id, confirmed: true))) },
        .init("groups", "", [:], "Read groups.") { _ in .init(.catalog(includeTags: false), projection: "groups") },
        .init("groups add", "name", ["name": .string], "Create group.") { .init(.group(.create($0.name))) },
        .init("groups rename", "id", ["id": .string, "name": .string], required: "name", "Rename group.") { .init(.group(.rename($0.id, name: $0.name))) },
        .init("groups delete", "id", ["id": .string, "confirmed": .bool], required: "confirmed", "Delete empty group only; confirmed must be true.") { .init(.group(.delete($0.id, confirmed: true))) },
        .init("sections", "", ["list": .string], "Read sections, optionally scoped by list ID or exact name.") { .init(.catalog(includeTags: false), projection: "sections" + ($0.text("list").map { ":" + $0 } ?? "")) },
        .init("sections add", "name", ["name": .string, "list": .string], required: "list", "Create section in list.") { .init(.section(.create(list: $0.list, name: $0.name))) },
        .init("sections rename", "id", ["id": .string, "list": .string, "name": .string], required: "list name", "Rename section in list.") { .init(.section(.rename(list: $0.list, section: $0.id, name: $0.name))) },
        .init("sections move", "id", ["id": .string, "list": .string, "position": Shapes.position], required: "list position", "Move section before/after a distinct neighbor in same list.") { try .init(.section(.move(list: $0.list, section: $0.id, position: $0.decode(Position.self, "position")))) },
        .init("sections delete", "id", ["id": .string, "list": .string, "confirmed": .bool], required: "list confirmed", "Delete section in list; confirmed must be true.") { .init(.section(.delete(list: $0.list, section: $0.id, confirmed: true))) },
        .init("tags", "", [:], "Read native tag labels with open/total counts from their selected reminders.") { _ in .init(.catalog(includeTags: true), projection: "tags") },
        .init("tags rename", "id", ["id": .string, "name": .string], required: "name", "Rename a native-matched tag and report affected reminder receipts.") { .init(.tag(.rename($0.id, name: $0.name))) },
        .init("tags delete", "id", ["id": .string, "confirmed": .bool], required: "confirmed", "Remove a native-matched tag from reminders; confirmed must be true.") { .init(.tag(.delete($0.id, confirmed: true))) },
        .init("smart-lists", "", [:], "Read smart lists, preserving opaque unknown filters; lists with unknown filters are read-only.") { _ in .init(.catalog(includeTags: false), projection: "smart-lists") },
        .init("smart-lists add", "name", ["name": .string, "definition": Shapes.smart], required: "definition", "Create native smart list; unsupported filter/account capabilities refuse explicitly.") { a in
            let smart = try a.merged(SmartList(id: "", name: a.name), "definition")
            guard smart.id.isEmpty, smart.name == a.name else { throw invalid("New smart-list identity belongs in name; id must be empty") }; return .init(.smartList(.create(smart)))
        },
        .init("smart-lists edit", "id", ["id": .string, "definition": Shapes.smart.requiring("id name match filters")], required: "definition", "Full replacement requires id/name/match/filters; unknown native filters cannot be erased.") { try .init(.smartList(.update($0.id, $0.decode(SmartList.self, "definition")))) },
        .init("smart-lists delete", "id", ["id": .string, "confirmed": .bool], required: "confirmed", "Delete smart list; confirmed must be true.") { .init(.smartList(.delete($0.id, confirmed: true))) },
        .init("templates", "", [:], "Read native templates.") { _ in .init(.catalog(includeTags: false), projection: "templates") },
        .init("templates add", "name", ["name": .string, "list": .string, "includeCompleted": .bool], required: "list", "Create template from list; includeCompleted defaults false.") { .init(.template(.create(name: $0.name, list: $0.list, includeCompleted: $0.bool("includeCompleted")))) },
        .init("templates use", "id", ["id": .string, "name": .string], "Instantiate native template as new list, optionally renamed.") { .init(.template(.use($0.id, newListName: $0.text("name")))) },
        .init("templates delete", "id", ["id": .string, "confirmed": .bool], required: "confirmed", "Delete template; confirmed must be true.") { .init(.template(.delete($0.id, confirmed: true))) }
    ]
    public static func prepare(_ name: String, arguments: [String: JSONValue]) throws -> PreparedOperation {
        guard let definition = definitions.first(where: { $0.toolName == name }),
              case .object(let values) = try Schema.object(definition.fields, required: definition.required).convert(.object(arguments)) else { throw invalid("Unknown operation: \(name)") }
        let input = Arguments(values: values)
        for key in definition.required where definition.isSwitch(key) { guard input.bool(key) else { throw invalid("\(key) must be true") } }
        for key in definition.positional { try Validation.name(input.string(key)) }
        return try definition.dispatch(input)
    }
}
