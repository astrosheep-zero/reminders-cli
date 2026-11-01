import Foundation
import ReminderCore

/// Untyped bridge dictionaries stay at the Native/ObjC boundary.
/// Missing required keys and unknown scalars are errors, not plausible defaults.
enum Translation {
    static let frequencies: [Frequency] = [.daily, .weekly, .monthly, .yearly, .hourly]
    static let units: [AlertUnit] = [.minutes, .hours, .days, .weeks, .months]
    static let priorities: [Priority: Int] = [.none: 0, .high: 1, .medium: 5, .low: 9]
    static let sorts: [ListSort: String] = [.manual: "manual", .due: "displayDate_asc", .creation: "creationDate_desc", .priority: "priority_desc", .title: "title_asc"]

    static func value<T>(_ raw: [String: Any], _ key: String, as: T.Type = T.self) throws -> T {
        guard let value = raw[key] as? T else { throw Failure(.backend, "Native response missing or invalid \(key)") }
        return value
    }
    static func object(_ raw: Any?) throws -> [String: Any]? {
        if raw is NSNull { return nil }
        guard let result = raw as? [String: Any] else { throw Failure(.backend, "Native read returned neither an object nor an explicit miss") }
        return result
    }
    static func date(_ components: DateComponents) throws -> ReminderDate {
        guard let year = components.year, let month = components.month, let day = components.day else {
            throw Failure(.unsupported, "Native date is not a complete civil date")
        }
        let civil = CalendarDate(year, month, day)
        if let hour = components.hour {
            return .localDateTime(civil, hour: hour, minute: components.minute ?? 0, second: components.second ?? 0)
        }
        guard components.minute == nil, components.second == nil else { throw Failure(.unsupported, "Native date contains a time without an hour") }
        return .date(civil)
    }
    static func components(_ date: ReminderDate) -> DateComponents {
        var result = DateComponents()
        result.calendar = Calendar(identifier: .gregorian)
        result.year = date.day.year; result.month = date.day.month; result.day = date.day.day
        if case .localDateTime(_, let hour, let minute, let second) = date {
            result.hour = hour; result.minute = minute; result.second = second
        }
        return result // Deliberately no timezone, timestamp, or midnight conversion.
    }
    static func recurrence(_ raw: [String: Any]) throws -> Recurrence {
        let index: Int = try value(raw, "frequency")
        guard frequencies.indices.contains(index) else { throw Failure(.unsupported, "Unknown native recurrence frequency \(index)") }
        for key in ["weeksOfTheYear", "daysOfTheYear", "setPositions"] {
            if let array = raw[key] as? [Int], !array.isEmpty { throw Failure(.unsupported, "Recurrence \(key) cannot be represented by Core") }
        }
        let pairs: [[Int]] = try value(raw, "weekdays")
        let weekdays = try pairs.map { pair -> RecurrenceDay in
            guard pair.count == 2, let day = Weekday(rawValue: pair[0]) else { throw Failure(.unsupported, "Unknown native recurrence weekday") }
            return RecurrenceDay(day, ordinal: pair[1] == 0 ? nil : pair[1])
        }
        var end: RecurrenceEnd?
        if let count = raw["count"] as? Int { end = .count(count) }
        if let instant = raw["endDate"] as? Date {
            let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: instant)
            end = .until(CalendarDate(c.year!, c.month!, c.day!))
        }
        return Recurrence(frequency: frequencies[index], interval: try value(raw, "interval"), weekdays: weekdays,
                          monthDays: raw["daysOfTheMonth"] as? [Int] ?? [], months: raw["monthsOfTheYear"] as? [Int] ?? [], end: end)
    }
    static func recurrence(_ rule: Recurrence) throws -> [String: Any] {
        guard let frequency = frequencies.firstIndex(of: rule.frequency), rule.interval > 0 else { throw Failure(.invalidInput, "Invalid recurrence") }
        var result: [String: Any] = ["frequency": frequency, "interval": rule.interval,
            "weekdays": rule.weekdays.map { [$0.day.rawValue, $0.ordinal ?? 0] },
            "daysOfTheMonth": rule.monthDays, "monthsOfTheYear": rule.months]
        switch rule.end {
        case .count(let count): result["count"] = count
        case .until(let day):
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
            guard let instant = calendar.date(from: components(.date(day))) else { throw Failure(.invalidInput, "Invalid recurrence end date") }
            result["endDate"] = instant
        case nil: break
        }
        return result
    }
    static func location(_ raw: [String: Any]) throws -> LocationAlert {
        if let event = raw["vehicle"] as? Int {
            switch event { case 1: return .gettingInCar; case 2: return .gettingOutOfCar
            default: throw Failure(.unsupported, "Unknown native vehicle event \(event)") }
        }
        let proximity: Int = try value(raw, "proximity")
        guard proximity == 1 || proximity == 2 else { throw Failure(.unsupported, "Unknown native location proximity \(proximity)") }
        return .place(title: try value(raw, "title"), latitude: try value(raw, "latitude"), longitude: try value(raw, "longitude"),
                      radius: try value(raw, "radius"), address: raw["address"] as? String, when: proximity == 1 ? .arriving : .leaving)
    }
    static func location(_ alert: LocationAlert) -> [String: Any] {
        switch alert {
        case .gettingInCar: return ["vehicle": 1]
        case .gettingOutOfCar: return ["vehicle": 2]
        case .place(let title, let latitude, let longitude, let radius, let address, let when):
            var result: [String: Any] = ["title": title, "latitude": latitude, "longitude": longitude, "radius": radius, "proximity": when == .arriving ? 1 : 2]
            result["address"] = address
            return result
        }
    }
    static func position(_ raw: [String: Any]?) throws -> Position? {
        guard let raw else { return nil }
        let id: String = try value(raw, "id"), after: Bool = try value(raw, "after")
        return after ? .after(id) : .before(id)
    }
    static func position(_ position: Position) -> [String: Any] {
        switch position { case .before(let id): ["id": id, "after": false]; case .after(let id): ["id": id, "after": true] }
    }
    static func reminder(_ raw: [String: Any]) throws -> Reminder {
        let number: Int = try value(raw, "priority")
        guard let priority = priorities.first(where: { $0.value == number })?.key else { throw Failure(.unsupported, "Unknown native priority \(number)") }
        let urls: [String] = try value(raw, "urls")
        guard urls.count <= 1 else { throw Failure(.unsupported, "Multiple native URL attachments cannot be represented without loss") }
        let early: [[Int]] = try value(raw, "early")
        let alerts = try early.map { pair -> EarlyAlert in
            guard pair.count == 2, units.indices.contains(pair[0]), pair[1] <= 0, pair[1] != Int.min else {
                throw Failure(.unsupported, "Unknown native early-alert interval")
            }
            return EarlyAlert(before: -pair[1], unit: units[pair[0]])
        }
        let contact = raw["contact"] as? [String: Any]
        let f = try ReminderFields(title: value(raw, "title"), listID: value(raw, "listID"), notes: raw["notesAsString"] as? String,
            due: (raw["dueDateComponents"] as? DateComponents).map(date), start: (raw["startDateComponents"] as? DateComponents).map(date),
            recurrence: (raw["repeat"] as? [String: Any]).map(recurrence), earlyAlerts: alerts,
            location: (raw["location"] as? [String: Any]).map(location),
            contact: contact.map { try ContactAlert(phones: value($0, "phones"), emails: value($0, "emails")) }, url: urls.first,
            priority: priority, flagged: value(raw, "flagged"), urgent: value(raw, "urgent"), completed: value(raw, "completed"),
            tags: value(raw, "tags"), parentID: raw["parentID"] as? String, sectionID: raw["sectionID"] as? String,
            position: position(raw["position"] as? [String: Any]), assigneeID: raw["assigneeID"] as? String)
        let images: [[String: Any]] = try value(raw, "images")
        return try Reminder(id: value(raw, "id"), fields: f, images: images.map { image in
            try ImageAttachment(id: value(image, "id"), fileName: value(image, "fileName"), contentType: value(image, "type"),
                byteCount: value(image, "size"))
        }, childIDs: value(raw, "childIDs"), creationDate: raw["creationDate"] as? Date,
            lastModifiedDate: raw["lastModifiedDate"] as? Date, completionDate: raw["completionDate"] as? Date)
    }
    /// Creation shares sparse translation without depending on Codable's associated-value layout.
    static func creationFields(_ f: ReminderFields) throws -> [String: Any] {
        func set<T>(_ value: T?) -> Change<T> { value.map(Change.set) ?? .absent }
        var p = ReminderPatch()
        p.title = .set(f.title); p.listID = .set(f.listID); p.notes = set(f.notes)
        p.due = set(f.due); p.start = set(f.start); p.recurrence = set(f.recurrence)
        p.earlyAlerts = .set(f.earlyAlerts); p.location = set(f.location); p.contact = set(f.contact); p.url = set(f.url)
        p.priority = .set(f.priority); p.flagged = .set(f.flagged); p.urgent = .set(f.urgent); p.completed = .set(f.completed)
        p.tags = .set(f.tags); p.parentID = set(f.parentID); p.sectionID = set(f.sectionID)
        p.position = set(f.position); p.assigneeID = set(f.assigneeID)
        return try patch(p)
    }
    static func patch(_ patch: ReminderPatch) throws -> [String: Any] {
        var result: [String: Any] = [:]
        func apply<T>(_ key: String, _ change: Change<T>, clear: Any = NSNull(), encode: (T) throws -> Any) throws {
            switch change {
            case .absent: break
            case .set(let value): result[key] = try encode(value)
            case .clear: result[key] = clear
            }
        }
        guard patch.title != .clear, patch.listID != .clear else { throw Failure(.invalidInput, "Title and list cannot be cleared") }
        guard patch.position != .clear else { throw Failure(.unsupported, "Native manual ordering has no clear-position operation") }
        for (key, change) in [("title", patch.title), ("listID", patch.listID), ("notes", patch.notes),
                              ("url", patch.url), ("parentID", patch.parentID), ("sectionID", patch.sectionID), ("assigneeID", patch.assigneeID)] {
            try apply(key, change) { $0 }
        }
        try apply("due", patch.due, encode: components)
        try apply("start", patch.start, encode: components)
        try apply("repeat", patch.recurrence, encode: recurrence)
        try apply("early", patch.earlyAlerts, clear: [[Int]]()) { alerts in
            try alerts.map { alert in
                guard let unit = units.firstIndex(of: alert.unit), alert.before >= 0 else { throw Failure(.invalidInput, "Invalid early reminder") }
                return [unit, -alert.before]
            }
        }
        try apply("location", patch.location, encode: location)
        try apply("contact", patch.contact) { ["phones": $0.phones, "emails": $0.emails] }
        try apply("priority", patch.priority, clear: 0) { priorities[$0]! }
        try apply("flagged", patch.flagged, clear: false) { $0 }
        try apply("urgent", patch.urgent, clear: false) { $0 }
        try apply("completed", patch.completed, clear: false) { $0 }
        try apply("tags", patch.tags, clear: [String]()) { $0 }
        try apply("position", patch.position, encode: position)
        if !patch.removeImageIDs.isEmpty { result["removeImages"] = patch.removeImageIDs }
        return result
    }
    static func listFields(_ fields: ListFields) throws -> [String: Any] {
        var result: [String: Any] = ["name": fields.name, "pinned": fields.pinned, "groceries": fields.kind == .groceries,
            "sorting": sorts[fields.sort]!, "groupID": fields.groupID as Any? ?? NSNull(), "icon": fields.icon as Any? ?? NSNull()]
        result["color"] = try color(fields.color) as Any? ?? NSNull()
        if let p = fields.position { result["position"] = position(p) }
        return result
    }
    static func color(_ color: String?) throws -> [String: Any]? {
        guard let color else { return nil }
        let palette = ["red": "#FF383C", "orange": "#FF8D28", "yellow": "#FFCC00", "green": "#83D754",
            "blue": "#0088FF", "purple": "#CB30E0", "brown": "#AC7F5E", "gray": "#5B626A", "pink": "#EA426A",
            "indigo": "#5856D6", "rose": "#D9A69F", "teal": "#30B0C7", "light-blue": "#5AC8FA"]
        if let hex = palette[color.lowercased()] { return ["name": color.lowercased() == "light-blue" ? "lightBlue" : color.lowercased(), "hex": hex] }
        // cyan's native symbolic form is a known trap; use the supported hex path.
        if color.lowercased() == "cyan" { return ["hex": "#5AC8FA"] }
        if color.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil { return ["hex": color.uppercased()] }
        throw Failure(.invalidInput, "Unsupported native color \(color)")
    }
    static func color(_ raw: [String: Any]?) -> String? {
        let name = raw?["name"] as? String
        return name == "custom" ? raw?["hex"] as? String : name == "lightBlue" ? "light-blue" : name
    }
    static func list(_ raw: [String: Any], defaultID: String) throws -> ReminderList {
        let nativeSort = raw["sorting"] as? String ?? "default"
        let sort: ListSort
        if nativeSort == "default" { sort = .manual }
        else if let known = sorts.first(where: { $0.value == nativeSort })?.key { sort = known }
        else { throw Failure(.unsupported, "Native list sorting \(nativeSort) cannot be represented") }
        let f = try ListFields(name: value(raw, "name"), color: color(raw["color"] as? [String: Any]),
            icon: raw["icon"] as? String, groupID: raw["groupID"] as? String, pinned: value(raw, "pinned"),
            kind: (value(raw, "groceries") as Bool) ? .groceries : .standard, sort: sort,
            position: position(raw["position"] as? [String: Any]))
        let members: [[String: Any]] = try value(raw, "members")
        let id: String = try value(raw, "id")
        return try ReminderList(id: id, fields: f, isDefault: id.caseInsensitiveCompare(defaultID) == .orderedSame,
            members: members.filter { ($0["status"] as? Int) == 1 }.map { try Member(id: value($0, "id"), name: value($0, "name"), isCurrentUser: value($0, "me")) })
    }
}
