import Foundation

public enum Validation {
    public static func query(_ query: ReminderQuery) throws {
        guard query.limit > 0, query.offset >= 0 else { throw Failure(.invalidInput, "Limit must be positive and offset nonnegative") }
        if let text = query.text, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw Failure(.invalidInput, "Search text must not be empty")
        }
        guard query.matching == nil || query.text != nil else { throw Failure(.invalidInput, "Matching requires text") }
        if query.smartList != nil && (query.completed != nil || query.text != nil || query.matching != nil || query.list != nil || query.flagged != nil || query.urgent != nil || query.repeating != nil || query.hasLocation != nil || query.hasDueDate != nil) {
            throw Failure(.invalidInput, "Smart list cannot be combined with search criteria")
        }
    }

    public static func date(_ date: CalendarDate) throws {
        guard (1...9999).contains(date.year), (1...12).contains(date.month), (1...31).contains(date.day) else {
            throw Failure(.invalidInput, "Invalid Gregorian date")
        }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: date.year, month: date.month, day: date.day)
        guard let instant = calendar.date(from: components),
              calendar.dateComponents([.year, .month, .day], from: instant) == components else {
            throw Failure(.invalidInput, "Invalid Gregorian date")
        }
    }
    public static func date(_ date: ReminderDate) throws {
        try self.date(date.day)
        if case .localDateTime(_, let h, let m, let s) = date {
            guard (0...23).contains(h), (0...59).contains(m), (0...59).contains(s) else {
                throw Failure(.invalidInput, "Invalid local time")
            }
        }
    }
    public static func components(_ date: ReminderDate) -> [Int] {
        let d = date.day
        if case .localDateTime(_, let h, let m, let s) = date { return [d.year, d.month, d.day, h, m, s] }
        return [d.year, d.month, d.day, 0, 0, 0]
    }
    public static func recurrence(_ rule: Recurrence, due: ReminderDate) throws {
        guard rule.interval > 0, rule.monthDays.allSatisfy({ (-31...31).contains($0) && $0 != 0 }),
              rule.months.allSatisfy({ (1...12).contains($0) }) else {
            throw Failure(.invalidInput, "Invalid recurrence interval, month or day")
        }
        for day in rule.weekdays {
            if let ordinal = day.ordinal {
                guard ordinal != 0, (-53...53).contains(ordinal),
                      rule.frequency == .monthly || rule.frequency == .yearly,
                      rule.frequency != .monthly || (-5...5).contains(ordinal) else {
                    throw Failure(.invalidInput, "Invalid recurrence weekday ordinal")
                }
            }
        }
        if case .count(let count) = rule.end, count <= 0 { throw Failure(.invalidInput, "Repeat count must be positive") }
        if case .until(let day) = rule.end {
            try date(day)
            guard day >= due.day else { throw Failure(.invalidInput, "Repeat end precedes due date") }
        }
    }
    public static func fields(_ f: ReminderFields, images: [ImageInput] = [], listRequired: Bool = true) throws {
        try name(f.title)
        guard !listRequired || !f.listID.isEmpty else { throw Failure(.invalidInput, "List is required") }
        if let due = f.due { try date(due) }
        if let start = f.start { try date(start) }
        if let due = f.due, let start = f.start,
           components(due).lexicographicallyPrecedes(components(start)) {
            throw Failure(.invalidInput, "Start is after due date")
        }
        if let recurrence = f.recurrence {
            guard let due = f.due else { throw Failure(.invalidInput, "Repeat requires due date") }
            try self.recurrence(recurrence, due: due)
        }
        guard f.earlyAlerts.isEmpty || f.due != nil, f.earlyAlerts.allSatisfy({ $0.before > 0 }) else {
            throw Failure(.invalidInput, "Early alerts require a due date and positive offset")
        }
        guard !f.urgent || f.due?.hasTime == true else { throw Failure(.invalidInput, "Urgent requires a timed due date") }
        if case .place(_, let lat, let lon, let radius, _, _) = f.location {
            guard lat.isFinite, lon.isFinite, radius.isFinite, (-90...90).contains(lat),
                  (-180...180).contains(lon), radius > 0 else { throw Failure(.invalidInput, "Invalid location") }
        }
        if let contact = f.contact {
            guard !contact.phones.isEmpty || !contact.emails.isEmpty,
                  (contact.phones + contact.emails).allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw Failure(.invalidInput, "Contact alert needs explicit phone or email")
            }
        }
        if let url = f.url, URL(string: url)?.scheme == nil { throw Failure(.invalidInput, "URL needs a scheme") }
        try tags(f.tags)
        for image in images {
            guard !image.bytes.isEmpty, image.bytes.count <= 16 * 1024 * 1024,
                  !image.fileName.isEmpty, image.fileName == (image.fileName as NSString).lastPathComponent,
                  image.fileName != ".", image.fileName != "..", !image.fileName.contains("\0"),
                  !image.contentType.isEmpty else { throw Failure(.invalidInput, "Invalid image bytes or metadata") }
        }
    }
    public static func tags(_ tags: [String]) throws {
        guard tags.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("#") && !$0.contains(where: \.isWhitespace) && !$0.contains("\0") }) else {
            throw Failure(.invalidInput, "Tags must be nonempty, without #, NUL or whitespace")
        }
    }
    public static func name(_ value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !value.contains("\0") else {
            throw Failure(.invalidInput, "Name must not be empty or contain NUL")
        }
    }
    static func list(_ fields: ListFields) throws {
        try name(fields.name)
        if let color = fields.color {
            let names = ["red", "orange", "yellow", "green", "light-blue", "blue", "indigo", "pink", "purple", "brown", "gray", "rose"]
            let hex = color.count == 7 && color.first == "#" && color.dropFirst().allSatisfy(\.isHexDigit)
            guard names.contains(color) || hex else { throw Failure(.invalidInput, "Invalid list color") }
        }
        if let icon = fields.icon { try name(icon) }
    }
    public static func filters(_ filters: [SmartFilter]) throws {
        for filter in filters {
            switch filter {
            case .unknown: throw Failure(.unsupported, "Unknown smart filters are read-only")
            case .tags(let values, _): try tags(values)
            case .priorities(let values):
                guard !values.contains(.none) else { throw Failure(.invalidInput, "Smart-filter priorities must be low, medium or high") }
            case .date(.range(let from, let before)):
                if let from { try date(from) }; if let before { try date(before) }
                if let from, let before, from >= before { throw Failure(.invalidInput, "Empty date range") }
            case .date(.relative(let past, let future, let unit)):
                guard past >= 0, future >= 0, (past > 0) != (future > 0), unit != .minutes else {
                    throw Failure(.invalidInput, "Relative range requires one positive direction and hour/day/week/month units")
                }
            default: break
            }
        }
    }
}
