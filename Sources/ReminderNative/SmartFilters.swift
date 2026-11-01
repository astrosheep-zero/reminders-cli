import Foundation
import ReminderCore

/// Stored ReminderKit filter schema. Unknown fields remain opaque bytes on reads;
/// they are never dropped, evaluated in Swift, or sent back as guessed edits.
enum SmartFilters {
    static func changes(_ patch: SmartListPatch, clear: [SmartListClear]) throws -> [String: Any] {
        try patch.validate(clear: clear)
        var result: [String: Any] = [:]
        if let name = patch.name { result["name"] = name }
        if let color = patch.color { result["color"] = try Translation.color(color) }
        if let icon = patch.icon { result["icon"] = icon }
        for field in clear { result[field.rawValue] = NSNull() }
        if patch.match != nil || patch.filters != nil {
            guard let match = patch.match, let filters = patch.filters else { throw Failure(.invalidInput, "Smart-filter edit requires Core's merged definition") }
            result["filterData"] = try data(filters, match: match)
        }
        return result
    }
    static func data(_ filters: [SmartFilter], match: MatchMode = .all) throws -> Data {
        try Validation.filters(filters)
        var root: [String: Any] = ["operation": match == .all ? "and" : "or"]
        for filter in filters {
            let pair: (String, Any)
            switch filter {
            case .unknown: throw Failure(.unsupported, "Editing unknown native smart-filter fields is unsupported")
            case .tags(let names, let match):
                pair = ("hashtags", ["hashtags": ["include": names, "exclude": [], "operation": match == .all ? "and" : "or"]])
            case .flagged(let flag): pair = ("flagged", flag)
            case .lists(let ids): pair = ("lists", ["include": ids, "exclude": [], "operation": ids.count > 1 ? "or" : "and"])
            case .priorities(let priorities): pair = ("priorities", priorities.map(\.rawValue))
            case .date(let date): pair = ("date", try storedDate(date))
            case .location(let location):
                switch location {
                case .none: pair = ("location", ["noLocation": ""])
                case .gettingInCar: pair = ("location", ["vehicle": "connected"])
                case .gettingOutOfCar: pair = ("location", ["vehicle": "disconnected"])
                }
            }
            root[pair.0] = pair.1
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }
    static func storedDay(_ day: CalendarDate) -> String { String(format: "%02d-%02d-%04d", day.day, day.month, day.year) }
    static func day(_ raw: Any?) -> CalendarDate? {
        guard let string = raw as? String else { return nil }
        let parts = string.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return CalendarDate(parts[2], parts[1], parts[0])
    }
    static func shifted(_ day: CalendarDate, by days: Int) throws -> CalendarDate {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let start = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day)),
              let shifted = calendar.date(byAdding: .day, value: days, to: start) else { throw Failure(.invalidInput, "Invalid smart-filter date") }
        let c = calendar.dateComponents([.year, .month, .day], from: shifted)
        return CalendarDate(c.year!, c.month!, c.day!)
    }
    static func storedDate(_ filter: DateFilter) throws -> [String: Any] {
        switch filter {
        case .none: return ["noDate": ""]
        case .any: return ["any": ""]
        case .range(let from, let before):
            switch (from, before) {
            case (.some(let from), .some(let before)): return ["dateRange": [storedDay(from), storedDay(try shifted(before, by: -1))]]
            case (.some(let from), nil): return ["afterDate": storedDay(try shifted(from, by: -1))]
            case (nil, .some(let before)): return ["beforeDate": storedDay(before)]
            case (nil, nil): throw Failure(.invalidInput, "Date range needs a bound")
            }
        case .relative(let past, let future, let unit):
            return ["relativeRange": ["direction": past > 0 ? "inPast" : "inNext", "magnitude": String(max(past, future)), "units": String(unit.rawValue.dropLast()), "includePastDue": false]]
        }
    }
    static func decode(_ raw: [String: Any]) throws -> SmartList {
        let data: Data = try Translation.value(raw, "filterData")
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(.backend, "Native smart filter is not a JSON object")
        }
        var filters: [SmartFilter] = []
        func opaque(_ key: String, _ value: Any) throws -> SmartFilter {
            .unknown(key: key, payload: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]))
        }
        for key in root.keys.sorted() where key != "operation" {
            let value = root[key]!
            let decoded: SmartFilter?
            switch key {
            case "flagged": decoded = (value as? Bool).map(SmartFilter.flagged)
            case "priorities":
                if let strings = value as? [String], strings.allSatisfy({ ["low", "medium", "high"].contains($0) }) {
                    decoded = .priorities(strings.map { Priority(rawValue: $0)! })
                } else { decoded = nil }
            case "lists":
                if let object = value as? [String: Any], Set(object.keys).isSubset(of: ["include", "exclude", "operation"]),
                   let ids = object["include"] as? [String], let excluded = object["exclude"] as? [String], excluded.isEmpty,
                   (object["operation"] == nil || ["and", "or"].contains(object["operation"] as? String ?? "")),
                   (ids.count <= 1 || object["operation"] as? String == "or") { decoded = .lists(ids) }
                else { decoded = nil }
            case "hashtags":
                if let outer = value as? [String: Any], Set(outer.keys) == ["hashtags"], let object = outer["hashtags"] as? [String: Any],
                   Set(object.keys) == ["include", "exclude", "operation"], let included = object["include"] as? [String],
                   let excluded = object["exclude"] as? [String], excluded.isEmpty,
                   let op = object["operation"] as? String, ["and", "or"].contains(op) {
                    decoded = .tags(included, match: op == "and" ? .all : .any)
                } else { decoded = nil }
            case "date": decoded = try decodeDate(value).map(SmartFilter.date)
            case "location":
                if let object = value as? [String: Any], object.count == 1 {
                    if object["noLocation"] as? String == "" { decoded = .location(.none) }
                    else if object["vehicle"] as? String == "connected" { decoded = .location(.gettingInCar) }
                    else if object["vehicle"] as? String == "disconnected" { decoded = .location(.gettingOutOfCar) }
                    else { decoded = nil }
                } else { decoded = nil }
            default: decoded = nil
            }
            filters.append(try decoded ?? opaque(key, value))
        }
        let operation = root["operation"] as? String
        if root["operation"] != nil && operation != "and" && operation != "or" { filters.append(try opaque("operation", root["operation"]!)) }
        return try SmartList(id: Translation.value(raw, "id"), name: Translation.value(raw, "name"),
            color: Translation.color(raw["color"] as? [String: Any]), icon: raw["icon"] as? String,
            match: operation == "or" ? .any : .all, filters: filters)
    }
    static func decodeDate(_ value: Any) throws -> DateFilter? {
        guard let object = value as? [String: Any], object.count == 1 else { return nil }
        if object["noDate"] as? String == "" { return .some(.none) }
        if object["any"] as? String == "" { return .some(.any) }
        if let before = day(object["beforeDate"]) { return .range(from: nil, before: before) }
        if let after = day(object["afterDate"]) { return .range(from: try shifted(after, by: 1), before: nil) }
        if let on = day(object["onDate"]) { return .range(from: on, before: try shifted(on, by: 1)) }
        if let range = object["dateRange"] as? [String], range.count == 2, let from = day(range[0]), let through = day(range[1]) {
            return .range(from: from, before: try shifted(through, by: 1))
        }
        if let range = object["relativeRange"] as? [String: Any], Set(range.keys) == ["direction", "magnitude", "units", "includePastDue"],
           range["includePastDue"] as? Bool == false, let text = range["magnitude"] as? String, let magnitude = Int(text), magnitude > 0,
           let direction = range["direction"] as? String, ["inPast", "inNext"].contains(direction),
           let unit = ["hour": AlertUnit.hours, "day": .days, "week": .weeks, "month": .months][range["units"] as? String ?? ""] {
            return .relative(past: direction == "inPast" ? magnitude : 0, future: direction == "inNext" ? magnitude : 0, unit: unit)
        }
        return nil
    }
}
