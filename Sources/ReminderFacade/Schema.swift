import Foundation
import ReminderCore

public func invalid(_ message: String) -> Failure { Failure(.invalidInput, message) }

/// One schema drives discovery, strict validation and the stable JSON/Core codec.
/// Core's Codable representation stays private to the one-shot worker protocol.
indirect enum Schema: Sendable {
    case scalar(String, [String] = [])
    case array(Schema)
    case object([String: Schema], required: Set<String> = [])
    case tagged([String: Schema])
    static let string = Self.scalar("string"), bool = Self.scalar("boolean"), int = Self.scalar("integer"), number = Self.scalar("number")
    static func choice(_ values: String) -> Self { .scalar("string", values.split(separator: " ").map(String.init)) }
    static func fields(_ values: [String: Schema], _ required: String = "") -> Self {
        .object(values, required: Set(required.split(separator: " ").map(String.init)))
    }
    var json: JSONValue {
        switch self {
        case .scalar(let type, let values):
            var result: [String: JSONValue] = ["type": .string(type)]
            if !values.isEmpty { result["enum"] = .array(values.map(JSONValue.string)) }
            return .object(result)
        case .array(let item): return .object(["type": .string("array"), "items": item.json])
        case .object(let fields, let required):
            return .object(["type": .string("object"), "properties": .object(fields.mapValues(\.json)),
                "required": .array(required.sorted().map(JSONValue.string)), "additionalProperties": .bool(false)])
        case .tagged(let cases):
            return .object(["oneOf": .array(cases.keys.filter { $0 != "unknown" }.sorted().map { tag in
                guard case .object(var fields, let required) = cases[tag]! else { preconditionFailure("Tagged payload must be an object") }
                fields["kind"] = .scalar("string", [tag])
                return Self.object(fields, required: required.union(["kind"])).json
            })])
        }
    }
    func convert(_ value: JSONValue, outward: Bool = false, path: String = "input") throws -> JSONValue {
        switch (self, value) {
        case (.scalar(let type, let choices), _):
            let valid: Bool
            switch (type, value) {
            case ("string", .string(let v)): valid = choices.isEmpty || choices.contains(v)
            case ("boolean", .bool): valid = true
            case ("number", .number): valid = true
            case ("integer", .number(let v)): valid = v == Decimal(Int64(clamping: NSDecimalNumber(decimal: v).int64Value))
            default: valid = false
            }
            guard valid else { throw invalid("\(path): expected \(type)\(choices.isEmpty ? "" : " (" + choices.joined(separator: ", ") + ")")") }
            return value
        case (.array(let schema), .array(let items)):
            return .array(try items.enumerated().map { try schema.convert($0.element, outward: outward, path: "\(path)[\($0.offset)]") })
        case (.object(let fields, let required), .object(let object)):
            guard Set(object.keys).isSubset(of: fields.keys), required.isSubset(of: object.keys) else {
                throw invalid("\(path): unknown fields \(Set(object.keys).subtracting(fields.keys).sorted()); missing \(required.subtracting(object.keys).sorted())")
            }
            return .object(try Dictionary(uniqueKeysWithValues: object.map { key, item in
                (key, try fields[key]!.convert(item, outward: outward, path: path + "." + key))
            }))
        case (.tagged(let cases), .object(var object)):
            let tag: String, payload: JSONValue
            if outward, object.count == 1, let pair = object.first, case .object(let body) = pair.value {
                tag = pair.key; payload = .object(Dictionary(uniqueKeysWithValues: body.map { ($0.key == "_0" ? "value" : $0.key, $0.value) }))
            } else if !outward, case .string(let kind) = object.removeValue(forKey: "kind") {
                tag = kind; payload = .object(object)
            } else { throw invalid("\(path): expected a tagged object with kind") }
            guard (outward || tag != "unknown"), let schema = cases[tag], case .object(let body) = try schema.convert(payload, outward: outward, path: path + "." + tag) else {
                throw invalid("\(path): unknown kind \(tag)")
            }
            if outward { return .object(body.merging(["kind": .string(tag)]) { _, new in new }) }
            return .object([tag: .object(Dictionary(uniqueKeysWithValues: body.map { ($0.key == "value" ? "_0" : $0.key, $0.value) }))])
        default: throw invalid("\(path): wrong JSON shape; null is not a clear operation")
        }
    }
    func requiring(_ names: String) -> Self {
        guard case .object(let fields, _) = self else { preconditionFailure("Expected object schema") }
        return .fields(fields, names)
    }
}

enum Shapes {
    static let date = Schema.fields(["year": .int, "month": .int, "day": .int], "year month day")
    static let reminderDate = Schema.tagged([
        "date": .fields(["value": date], "value"),
        "localDateTime": .fields(["value": date, "hour": .int, "minute": .int, "second": .int], "value hour minute second")])
    static let position = Schema.tagged(["before": .fields(["value": .string], "value"), "after": .fields(["value": .string], "value")])
    static let unit = Schema.choice("minutes hours days weeks months"), priority = Schema.choice("none low medium high")
    static let location = Schema.tagged([
        "place": .fields(["title": .string, "latitude": .number, "longitude": .number, "radius": .number, "address": .string, "when": .choice("arriving leaving")], "title latitude longitude radius when"),
        "gettingInCar": .fields([:]), "gettingOutOfCar": .fields([:])])
    static let reminderFields: [String: Schema] = [
        "title": .string, "listID": .string, "notes": .string, "due": reminderDate, "start": reminderDate,
        "recurrence": .fields(["frequency": .choice("hourly daily weekly monthly yearly"), "interval": .int,
            "weekdays": .array(.fields(["day": .int, "ordinal": .int], "day")), "monthDays": .array(.int), "months": .array(.int),
            "end": .tagged(["count": .fields(["value": .int], "value"), "until": .fields(["value": date], "value")])], "frequency interval weekdays monthDays months"),
        "earlyAlerts": .array(.fields(["before": .int, "unit": unit], "before unit")), "location": location,
        "contact": .fields(["phones": .array(.string), "emails": .array(.string)], "phones emails"), "url": .string,
        "priority": priority, "flagged": .bool, "urgent": .bool, "completed": .bool, "tags": .array(.string),
        "parentID": .string, "sectionID": .string, "position": position, "assigneeID": .string]
    static let fields = Schema.fields(reminderFields)
    static let query = Schema.fields(["text": .string, "matching": .choice("exact prefix word"),
        "tags": .array(.string), "excludeTags": .array(.string), "tagMatch": .choice("all any"), "list": .string, "smartList": .string,
        "includeCompleted": .bool, "completed": .bool, "flagged": .bool, "urgent": .bool, "repeating": .bool, "hasLocation": .bool,
        "hasDueDate": .bool, "limit": .int, "offset": .int])
    static let list = Schema.fields(["name": .string, "color": .string, "icon": .string, "groupID": .string,
        "pinned": .bool, "kind": .choice("standard groceries"), "sort": .choice("manual due creation priority title"), "position": position])
    static let filter = Schema.tagged([
        "tags": .fields(["value": .array(.string), "match": .choice("all any")], "value match"),
        "date": .fields(["value": .tagged(["none": .fields([:]), "any": .fields([:]),
            "range": .fields(["from": date, "before": date]), "relative": .fields(["past": .int, "future": .int, "unit": .choice("hours days weeks months")], "past future unit")])], "value"),
        "priorities": .fields(["value": .array(.choice("low medium high"))], "value"), "flagged": .fields(["value": .bool], "value"),
        "lists": .fields(["value": .array(.string)], "value"), "location": .fields(["value": .choice("none gettingInCar gettingOutOfCar")], "value"),
        "unknown": .fields(["key": .string, "payload": .string], "key payload")])
    static let smart = Schema.fields(["id": .string, "name": .string, "color": .string, "icon": .string,
        "match": .choice("all any"), "filters": .array(filter)])
    static let images = Schema.array(.fields(["fileName": .string, "contentType": .string, "bytes": .string], "fileName contentType bytes"))
}
