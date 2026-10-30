import Foundation

enum HumanOutput {
    static func render(_ result: JSONValue) -> String {
        let root = result.object, kind = root["kind"]?.string ?? "result"
        switch kind {
        case "reminders": return rows(root["reminders"]) { reminder($0.object) }
        case "mutation":
            let mutation = root["mutation"]?.object ?? [:]
            var lines = ["Changed \(mutation["count"]?.integer ?? 0) record(s)."]
            lines += mutation["affectedIDs"]?.array.map { $0.string ?? "?" } ?? []
            lines += mutation["reminders"]?.array.map { reminder($0.object) } ?? []
            lines += mutation["lists"]?.array.map { entity($0.object, kind: "lists") } ?? []
            return lines.joined(separator: "\n") + "\n"
        case "deleted":
            return "Deletion history: toolOnly (not system Recently Deleted)\n" + rows(root["entries"]) { entry in
                let item = entry.object
                return "\(item["id"]?.string ?? "?")  \(item["title"]?.string ?? "")  [\(item["state"]?.string ?? "?")]  list=\(item["listID"]?.string ?? "?")"
            }
        case "diagnostics":
            let d = root["diagnostics"]?.object ?? [:]
            var lines = ["authorization: \(d["authorization"]?.string ?? "unknown")", "sandbox: \(d["sandbox"]?.string ?? "unknown")", "buildID: \(d["buildID"]?.string ?? "unknown")"]
            for key in ["bundle", "signature", "readProbe", "tccOwnership"] {
                let check = d[key]?.object ?? [:]
                lines.append("\(key): \(check["status"]?.string ?? "unverified") — \(check["message"]?.string ?? "")")
                if let error = check["error"] { lines.append("  \(error.object["code"]?.string ?? "backend"): \(error.object["message"]?.string ?? "")") }
            }
            lines.append("declared capabilities: \(d["capabilities"]?.array.count ?? 0) entries; use --json for details")
            return lines.joined(separator: "\n") + "\n"
        case "lists", "groups", "sections", "tags", "smartLists", "templates":
            return rows(root[kind]) { entity($0.object, kind: kind) }
        case "catalog":
            let catalog = root["catalog"]?.object ?? [:]
            return ["lists", "groups", "sections", "tags", "smartLists", "templates"].map { "\($0): \(catalog[$0]?.array.count ?? 0)" }.joined(separator: "; ") + "; use --json for records.\n"
        case "image":
            let image = root["image"]?.object ?? [:]
            return "Image: \(image["fileName"]?.string ?? "?") (\(image["contentType"]?.string ?? "?")); use --json for base64 bytes.\n"
        case "help": return (root["help"]?.string ?? "") + "\n"
        default: return "ok (\(kind)); use --json for complete fields.\n"
        }
    }
    private static func rows(_ value: JSONValue?, format: (JSONValue) -> String) -> String {
        let values = value?.array ?? []
        return values.isEmpty ? "No records.\n" : values.map(format).joined(separator: "\n") + "\n"
    }
    private static func reminder(_ item: [String: JSONValue]) -> String {
        let fields = item["fields"]?.object ?? [:]
        let status = fields["completed"] == .bool(true) ? "[x]" : "[ ]"
        var line = "\(item["id"]?.string ?? "?")  \(status) \(fields["title"]?.string ?? "")"
        if let due = fields["due"] { line += "  due=\(date(due))" }
        line += "  list=\(fields["listID"]?.string ?? "?")"
        if let version = item["version"]?.string { line += "  version=\(version)" }
        return line
    }
    private static func entity(_ item: [String: JSONValue], kind: String) -> String {
        let fields = item["fields"]?.object ?? item
        var line = "\(item["id"]?.string ?? "")  \(fields["name"]?.string ?? "?")"
        if kind == "tags" { line += "  open=\(item["openCount"]?.integer ?? 0) total=\(item["totalCount"]?.integer ?? 0)" }
        if item["isDefault"] == .bool(true) { line += "  [default]" }
        if let members = item["members"]?.array, !members.isEmpty {
            line += "  members=" + members.map { "\($0.object["name"]?.string ?? "?")(\($0.object["id"]?.string ?? "?"))" }.joined(separator: ",")
        }
        if let list = item["listID"]?.string { line += "  list=\(list)" }
        return line.trimmingCharacters(in: .whitespaces)
    }
    private static func date(_ value: JSONValue) -> String {
        let tag = value.object, timed = tag["localDateTime"]?.object
        let data = timed ?? tag["date"]?.object ?? [:], day = data["_0"]?.object ?? [:]
        var text = String(format: "%04d-%02d-%02d", day["year"]?.integer ?? 0, day["month"]?.integer ?? 0, day["day"]?.integer ?? 0)
        if timed != nil { text += String(format: "T%02d:%02d:%02d", data["hour"]?.integer ?? 0, data["minute"]?.integer ?? 0, data["second"]?.integer ?? 0) }
        return text
    }
}

private extension JSONValue {
    var object: [String: JSONValue] { if case .object(let value) = self { value } else { [:] } }
    var array: [JSONValue] { if case .array(let value) = self { value } else { [] } }
    var string: String? { if case .string(let value) = self { value } else { nil } }
    var integer: Int? { if case .number(let value) = self, value >= Decimal(Int.min), value <= Decimal(Int.max) { NSDecimalNumber(decimal: value).intValue } else { nil } }
}
