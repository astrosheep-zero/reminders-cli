import Foundation
import ReminderCore

public enum OperationEffect: Sendable {
    case read, additive, replacing, journal
}

public struct OperationDefinition: Sendable {
    public let name: String
    public let effect: OperationEffect
    public let positional: [String]
    public let summary: String
    let fields: [String: Schema]
    let required: Set<String>
    let dispatch: @Sendable (Arguments) throws -> WorkerRequest
    public var toolName: String { name.replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_") }
    public var inputSchema: JSONValue { Schema.object(fields, required: required).json }
    public var readOnly: Bool { effect == .read }
    public var destructive: Bool { effect == .replacing || effect == .journal }
    public var idempotent: Bool { effect == .read }
    init(_ name: String, _ effect: OperationEffect, _ positional: String = "", _ fields: [String: Schema] = [:], required: String = "", _ summary: String,
         dispatch: @escaping @Sendable (Arguments) throws -> WorkerRequest) {
        self.name = name; self.effect = effect; self.positional = positional.split(separator: " ").map(String.init)
        self.fields = fields; self.required = Set(required.split(separator: " ").map(String.init)).union(self.positional)
        self.summary = summary; self.dispatch = dispatch
    }
    /// CLI names adapt the same parameters; no separate command allowlist or dispatch switch.
    public var options: [String: String] {
        var result = Dictionary(uniqueKeysWithValues: fields.keys.filter { !positional.contains($0) && $0 != "images" }.map { key in
            let option = ["fields": "fields-json", "set": "set-json", "definition": "definition-json",
                "position": "position-json", "confirmed": "yes", "includeCompleted": "include-completed", "removeImageIDs": "remove-images"][key] ?? key
            if name == "find" {
                let kebab = key.reduce(into: "") { result, char in
                    if char.isUppercase { result.append("-"); result.append(contentsOf: char.lowercased()) } else { result.append(char) }
                }
                return (kebab + (["tags", "excludeTags"].contains(key) ? "-json" : ""), key)
            }
            return (option, key)
        })
        if name == "find" { result["query-json"] = "query" }
        if fields["images"] != nil { result["image"] = "image"; result["image-type"] = "image-type" }
        return result
    }
    public func isSwitch(_ key: String) -> Bool { if name == "find" { return key == "includeCompleted" }; if case .scalar("boolean", _) = fields[key] { return true }; return false }
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
        .init("doctor", .read, "", [:], "Inspect bundle/signature/authorization. Sentinel read only if already authorized; never prompts. A diagnostic report is not proof every check passed.") { _ in .doctor },
        .init("find", .read, "", Shapes.query, "Find using native criteria or a smart list. completed overrides includeCompleted for ordinary queries. Default excludes completed; limit 100, offset 0. CLI --query-json expands these fields; duplicate sources are rejected. Boolean filters take true/false; --include-completed is a switch.") { a in
            let query = try Arguments(values: ["query": .object(a.values)]).merged(ReminderQuery(), "query")
            try Validation.query(query); return .operation(.find(query))
        },
        .init("show", .read, "id", ["id": .string], "Show ID or native title-equals match, including an optimistic version token.") { .operation(.show($0.id)) },
        .init("add", .additive, "title", ["title": .string, "list": .string, "fields": Shapes.fields, "images": Shapes.images], "Create a reminder in the supplied list, parent's list or unique default list. Images are base64 bytes, never worker paths.") { a in
            let fields = try a.merged(ReminderFields(title: a.string("title"), listID: a.list), "fields")
            guard fields.title == a.string("title"), a.text("list") == nil || fields.listID == a.list else { throw invalid("Conflicting create title/list identity") }
            let images = try a.values["images"].map { _ in try a.decode([ImageInput].self, "images") } ?? []
            try Validation.fields(fields, images: images, listRequired: false); return .operation(.create(ReminderDraft(fields: fields, images: images)))
        },
        .init("edit", .replacing, "id", ["id": .string, "version": .string, "set": Shapes.fields, "clear": .array(.choice(Shapes.reminderFields.keys.sorted().joined(separator: " "))), "images": Shapes.images, "removeImageIDs": .array(.string)], required: "version", "Sparse edit: omitted fields stay unchanged; set values or explicitly clear. Requires latest version; not atomic cross-device CAS.") { try .operation(.update(id: $0.id, version: $0.version, patch: $0.patch())) },
        .init("done", .replacing, "id", ["id": .string, "version": .string, "undo": .bool], required: "version", "Complete reminder; undo=true marks incomplete. Requires version.") { .operation(.complete(id: $0.id, version: $0.version, completed: !$0.bool("undo"))) },
        .init("delete", .replacing, "id", ["id": .string, "version": .string], required: "version", "Soft-delete reminder and known children with journal evidence. Requires version; no purge.") { .operation(.delete(id: $0.id, version: $0.version)) },
        .init("deleted", .journal, "", [:], "Reconcile and prune this tool's persistent deletion journal (toolOnly), not system Recently Deleted.") { _ in .operation(.deleted) },
        .init("catalog", .read, "", [:], "Read all catalog families including native tag selections and counts.") { _ in .operation(.catalog(.all)) },
        .init("restore", .additive, "id", ["id": .string, "list": .string], "Restore root/children to saved destination or explicit list. Never retries uncertain saves.") { .operation(.restore(id: $0.id, list: $0.text("list"))) },
        .init("image", .read, "id imageID", ["id": .string, "imageID": .string], "Explicit image bytes read, returned as base64. May fail with native permission error; no prompt or invented permission fix.") { .operation(.image(reminderID: $0.id, imageID: $0.string("imageID"))) },
        .init("lists", .read, "", [:], "Read list metadata, default marker and already-joined members; no invitations.") { _ in .operation(.catalog(.lists)) },
        .init("lists add", .additive, "name", ["name": .string, "fields": Shapes.list], "Create list with optional appearance, grouping and sorting fields.") { a in
            let fields = try a.merged(ListFields(name: a.name), "fields")
            guard fields.name == a.name else { throw invalid("Use name for list creation identity") }; return .operation(.list(.create(fields)))
        },
        .init("lists edit", .replacing, "id", ["id": .string, "fields": Shapes.list, "clear": .array(.choice("color icon groupID"))], "Sparse list edit: omitted fields stay unchanged. Explicit clear accepts color/icon/groupID; omitted position never reorders.") { a in
            let patch = try a.merged(ListPatch(), "fields"), clear = try a.values["clear"].map { _ in try a.decode([ListClear].self, "clear") } ?? []
            try patch.validate(clear: clear); return .operation(.list(.update(a.id, patch, clear: clear)))
        },
        .init("lists delete", .replacing, "id", ["id": .string, "confirmed": .bool], required: "confirmed", "Delete list and contents; confirmed must be true. Journals selected reminders first.") { .operation(.list(.delete($0.id, confirmed: true))) },
        .init("lists clear-completed", .replacing, "id", ["id": .string, "confirmed": .bool], required: "confirmed", "Soft-delete completed reminders and selected parents' children; confirmed must be true.") { .operation(.list(.clearCompleted($0.id, confirmed: true))) },
        .init("groups", .read, "", [:], "Read groups.") { _ in .operation(.catalog(.groups)) },
        .init("groups add", .additive, "name", ["name": .string], "Create group.") { .operation(.group(.create($0.name))) },
        .init("groups rename", .replacing, "id", ["id": .string, "name": .string], required: "name", "Rename group.") { .operation(.group(.rename($0.id, name: $0.name))) },
        .init("groups delete", .replacing, "id", ["id": .string, "confirmed": .bool], required: "confirmed", "Delete empty group only; confirmed must be true.") { .operation(.group(.delete($0.id, confirmed: true))) },
        .init("sections", .read, "", ["list": .string], "Read sections, optionally scoped by list ID or exact name.") { .operation(.catalog(.sections, list: $0.text("list"))) },
        .init("sections add", .additive, "name", ["name": .string, "list": .string], required: "list", "Create section in list.") { .operation(.section(.create(list: $0.list, name: $0.name))) },
        .init("sections edit", .replacing, "id", ["id": .string, "list": .string, "set": .fields(["name": .string, "position": Shapes.position])], required: "list set", "Sparse section edit: rename and/or order before/after a distinct neighbor in the same list, in one save.") { a in
            let patch = try a.decode(SectionPatch.self, "set"); try patch.validate()
            return .operation(.section(.update(list: a.list, section: a.id, patch: patch)))
        },
        .init("sections delete", .replacing, "id", ["id": .string, "list": .string, "confirmed": .bool], required: "list confirmed", "Delete section in list; confirmed must be true.") { .operation(.section(.delete(list: $0.list, section: $0.id, confirmed: true))) },
        .init("tags", .read, "", [:], "Read native tag labels with open/total counts from their selected reminders.") { _ in .operation(.catalog(.tags)) },
        .init("tags rename", .replacing, "id", ["id": .string, "name": .string], required: "name", "Rename a native-matched tag and report affected reminder receipts.") { .operation(.tag(.rename($0.id, name: $0.name))) },
        .init("tags delete", .replacing, "id", ["id": .string, "confirmed": .bool], required: "confirmed", "Remove a native-matched tag from reminders; confirmed must be true.") { .operation(.tag(.delete($0.id, confirmed: true))) },
        .init("smart-lists", .read, "", [:], "Read smart lists, preserving opaque unknown filters; lists with unknown filters are read-only.") { _ in .operation(.catalog(.smartLists)) },
        .init("smart-lists add", .additive, "name", ["name": .string, "definition": Shapes.smart], required: "definition", "Create native smart list; unsupported filter/account capabilities refuse explicitly.") { a in
            let smart = try a.merged(SmartList(id: "", name: a.name), "definition")
            guard smart.id.isEmpty, smart.name == a.name else { throw invalid("New smart-list identity belongs in name; id must be empty") }; return .operation(.smartList(.create(smart)))
        },
        .init("smart-lists edit", .replacing, "id", ["id": .string, "definition": Shapes.smart.requiring("id name match filters")], required: "definition", "Full replacement requires id/name/match/filters; unknown native filters cannot be erased.") { try .operation(.smartList(.update($0.id, $0.decode(SmartList.self, "definition")))) },
        .init("smart-lists delete", .replacing, "id", ["id": .string, "confirmed": .bool], required: "confirmed", "Delete smart list; confirmed must be true.") { .operation(.smartList(.delete($0.id, confirmed: true))) },
        .init("templates", .read, "", [:], "Read native templates.") { _ in .operation(.catalog(.templates)) },
        .init("templates add", .additive, "name", ["name": .string, "list": .string, "includeCompleted": .bool], required: "list", "Create template from list; includeCompleted defaults false.") { .operation(.template(.create(name: $0.name, list: $0.list, includeCompleted: $0.bool("includeCompleted")))) },
        .init("templates use", .additive, "id", ["id": .string, "name": .string], "Instantiate native template as new list, optionally renamed.") { .operation(.template(.use($0.id, newListName: $0.text("name")))) },
        .init("templates delete", .replacing, "id", ["id": .string, "confirmed": .bool], required: "confirmed", "Delete template; confirmed must be true.") { .operation(.template(.delete($0.id, confirmed: true))) }
    ]
    public static func prepare(_ name: String, arguments: [String: JSONValue]) throws -> WorkerRequest {
        guard let definition = definitions.first(where: { $0.toolName == name }),
              case .object(let values) = try Schema.object(definition.fields, required: definition.required).convert(.object(arguments)) else { throw invalid("Unknown operation: \(name)") }
        let input = Arguments(values: values)
        for key in definition.required where definition.isSwitch(key) { guard input.bool(key) else { throw invalid("\(key) must be true") } }
        for key in definition.positional { try Validation.name(input.string(key)) }
        return try definition.dispatch(input)
    }
}
