import Foundation
import CryptoKit

public enum Change<Value: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    case absent, set(Value), clear
    public func applying(to value: Value?, cleared: Value? = nil) -> Value? {
        switch self { case .absent: value; case .set(let new): new; case .clear: cleared }
    }
}

/// Civil Gregorian components, never an absolute instant or an implicit timezone conversion.
public struct CalendarDate: Codable, Sendable, Equatable, Comparable {
    public var year: Int
    public var month: Int
    public var day: Int
    public init(_ year: Int, _ month: Int, _ day: Int) { self.year = year; self.month = month; self.day = day }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        [lhs.year, lhs.month, lhs.day].lexicographicallyPrecedes([rhs.year, rhs.month, rhs.day])
    }
}
public enum ReminderDate: Codable, Sendable, Equatable {
    case date(CalendarDate)
    case localDateTime(CalendarDate, hour: Int, minute: Int, second: Int)
    public var day: CalendarDate {
        switch self { case .date(let date), .localDateTime(let date, _, _, _): date }
    }
    public var hasTime: Bool { if case .localDateTime = self { true } else { false } }
}
public enum Priority: String, Codable, Sendable, CaseIterable { case none, low, medium, high }
public enum Frequency: String, Codable, Sendable { case hourly, daily, weekly, monthly, yearly }
public enum Weekday: Int, Codable, Sendable { case sunday = 1, monday, tuesday, wednesday, thursday, friday, saturday }
public struct RecurrenceDay: Codable, Sendable, Equatable {
    public var day: Weekday
    /// nil = every occurrence; signed ordinal in the month/year (never zero).
    public var ordinal: Int?
    public init(_ day: Weekday, ordinal: Int? = nil) { self.day = day; self.ordinal = ordinal }
}
public enum RecurrenceEnd: Codable, Sendable, Equatable { case count(Int), until(CalendarDate) }
public struct Recurrence: Codable, Sendable, Equatable {
    public var frequency: Frequency
    public var interval: Int
    public var weekdays: [RecurrenceDay]
    public var monthDays: [Int]
    public var months: [Int]
    public var end: RecurrenceEnd?
    public init(frequency: Frequency, interval: Int = 1, weekdays: [RecurrenceDay] = [],
                monthDays: [Int] = [], months: [Int] = [], end: RecurrenceEnd? = nil) {
        self.frequency = frequency; self.interval = interval; self.weekdays = weekdays
        self.monthDays = monthDays; self.months = months; self.end = end
    }
}
public enum AlertUnit: String, Codable, Sendable { case minutes, hours, days, weeks, months }
public struct EarlyAlert: Codable, Sendable, Equatable {
    public var before: Int
    public var unit: AlertUnit
    public init(before: Int, unit: AlertUnit) { self.before = before; self.unit = unit }
}
public enum LocationTrigger: String, Codable, Sendable { case arriving, leaving }
public enum LocationAlert: Codable, Sendable, Equatable {
    case place(title: String, latitude: Double, longitude: Double, radius: Double, address: String?, when: LocationTrigger)
    case gettingInCar, gettingOutOfCar
}
public struct ContactAlert: Codable, Sendable, Equatable {
    public var phones: [String]
    public var emails: [String]
    public init(phones: [String] = [], emails: [String] = []) { self.phones = phones; self.emails = emails }
}
/// Frontend supplies bytes, not a path which a permission-isolated worker might not read.
public struct ImageInput: Codable, Sendable, Equatable {
    public var fileName: String
    public var contentType: String
    public var bytes: Data
    public init(fileName: String, contentType: String, bytes: Data) {
        self.fileName = fileName; self.contentType = contentType; self.bytes = bytes
    }
}
public struct ImageAttachment: Codable, Sendable, Equatable {
    public var id: String
    public var fileName: String
    public var contentType: String
    public var byteCount: Int
    public var contentHash: String
    public init(id: String, fileName: String, contentType: String, byteCount: Int, contentHash: String) {
        self.id = id; self.fileName = fileName; self.contentType = contentType
        self.byteCount = byteCount; self.contentHash = contentHash
    }
}
public enum Position: Codable, Sendable, Equatable { case before(String), after(String)
    public var neighborID: String { switch self { case .before(let id), .after(let id): id } }
}

/// All editable visible state is held here and participates in version hashing.
public struct ReminderFields: Codable, Sendable, Equatable {
    public var title: String
    public var listID: String
    public var notes: String?
    public var due: ReminderDate?
    public var start: ReminderDate?
    public var recurrence: Recurrence?
    public var earlyAlerts: [EarlyAlert]
    public var location: LocationAlert?
    public var contact: ContactAlert?
    public var url: String?
    public var priority: Priority
    public var flagged: Bool
    public var urgent: Bool
    public var completed: Bool
    public var tags: [String]
    public var parentID: String?
    public var sectionID: String?
    public var position: Position?
    public var assigneeID: String?
    public init(title: String, listID: String, notes: String? = nil, due: ReminderDate? = nil,
                start: ReminderDate? = nil, recurrence: Recurrence? = nil, earlyAlerts: [EarlyAlert] = [],
                location: LocationAlert? = nil, contact: ContactAlert? = nil, url: String? = nil,
                priority: Priority = .none, flagged: Bool = false, urgent: Bool = false,
                completed: Bool = false, tags: [String] = [], parentID: String? = nil,
                sectionID: String? = nil, position: Position? = nil, assigneeID: String? = nil) {
        self.title = title; self.listID = listID; self.notes = notes; self.due = due; self.start = start
        self.recurrence = recurrence; self.earlyAlerts = earlyAlerts; self.location = location
        self.contact = contact; self.url = url; self.priority = priority; self.flagged = flagged
        self.urgent = urgent; self.completed = completed; self.tags = tags; self.parentID = parentID
        self.sectionID = sectionID; self.position = position; self.assigneeID = assigneeID
    }
}
public struct Reminder: Codable, Sendable, Equatable {
    public var id: String
    public var fields: ReminderFields
    public var images: [ImageAttachment]
    public var childIDs: [String]
    public init(id: String, fields: ReminderFields, images: [ImageAttachment] = [], childIDs: [String] = []) {
        self.id = id; self.fields = fields; self.images = images; self.childIDs = childIDs
    }
    /// SHA-256 of sorted-key JSON. Set-like collections are canonicalized; semantic order is preserved.
    public func version() throws -> String {
        var canonical = self
        canonical.id = id.lowercased(); canonical.fields.listID = fields.listID.lowercased()
        canonical.fields.parentID = fields.parentID?.lowercased(); canonical.fields.sectionID = fields.sectionID?.lowercased()
        canonical.fields.assigneeID = fields.assigneeID?.lowercased()
        canonical.childIDs = childIDs.map { $0.lowercased() }.sorted()
        canonical.fields.tags.sort()
        canonical.fields.contact?.phones.sort(); canonical.fields.contact?.emails.sort()
        canonical.fields.recurrence?.monthDays.sort(); canonical.fields.recurrence?.months.sort()
        canonical.fields.recurrence?.weekdays.sort {
            ($0.day.rawValue, $0.ordinal ?? 0) < ($1.day.rawValue, $1.ordinal ?? 0)
        }
        canonical.fields.earlyAlerts.sort { ($0.unit.rawValue, $0.before) < ($1.unit.rawValue, $1.before) }
        if let position = fields.position {
            switch position {
            case .before(let id): canonical.fields.position = .before(id.lowercased())
            case .after(let id): canonical.fields.position = .after(id.lowercased())
            }
        }
        canonical.images = images.map { image in var copy = image; copy.id = image.id.lowercased(); return copy }
            .sorted { ($0.id, $0.fileName, $0.contentHash) < ($1.id, $1.fileName, $1.contentHash) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return SHA256.hash(data: try encoder.encode(canonical)).map { String(format: "%02x", $0) }.joined()
    }
}
public struct ReminderPatch: Codable, Sendable, Equatable {
    public var title: Change<String> = .absent
    public var listID: Change<String> = .absent
    public var notes: Change<String> = .absent
    public var due: Change<ReminderDate> = .absent
    public var start: Change<ReminderDate> = .absent
    public var recurrence: Change<Recurrence> = .absent
    public var earlyAlerts: Change<[EarlyAlert]> = .absent
    public var location: Change<LocationAlert> = .absent
    public var contact: Change<ContactAlert> = .absent
    public var url: Change<String> = .absent
    public var priority: Change<Priority> = .absent
    public var flagged: Change<Bool> = .absent
    public var urgent: Change<Bool> = .absent
    public var completed: Change<Bool> = .absent
    public var tags: Change<[String]> = .absent
    public var parentID: Change<String> = .absent
    public var sectionID: Change<String> = .absent
    public var position: Change<Position> = .absent
    public var assigneeID: Change<String> = .absent
    public var addImages: [ImageInput] = []
    public var removeImageIDs: [String] = []
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case title, listID, notes, due, start, recurrence, earlyAlerts, location, contact, url
        case priority, flagged, urgent, completed, tags, parentID, sectionID, position, assigneeID, addImages, removeImageIDs
    }
    /// Omitted keys mean absent. Null is not a Change and must not silently erase state.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func change<T>(_ key: CodingKeys) throws -> Change<T> where T: Codable & Sendable & Equatable {
            values.contains(key) ? try values.decode(Change<T>.self, forKey: key) : .absent
        }
        title = try change(.title); listID = try change(.listID); notes = try change(.notes)
        due = try change(.due); start = try change(.start); recurrence = try change(.recurrence)
        earlyAlerts = try change(.earlyAlerts); location = try change(.location); contact = try change(.contact)
        url = try change(.url); priority = try change(.priority); flagged = try change(.flagged)
        urgent = try change(.urgent); completed = try change(.completed); tags = try change(.tags)
        parentID = try change(.parentID); sectionID = try change(.sectionID); position = try change(.position)
        assigneeID = try change(.assigneeID)
        addImages = values.contains(.addImages) ? try values.decode([ImageInput].self, forKey: .addImages) : []
        removeImageIDs = values.contains(.removeImageIDs) ? try values.decode([String].self, forKey: .removeImageIDs) : []
    }
    public func applying(to old: ReminderFields) throws -> ReminderFields {
        guard title != .clear, listID != .clear else { throw Failure(.invalidInput, "Title and list cannot be cleared") }
        var f = old
        f.title = title.applying(to: f.title) ?? ""; f.listID = listID.applying(to: f.listID) ?? ""
        f.notes = notes.applying(to: f.notes); f.due = due.applying(to: f.due)
        f.start = start.applying(to: f.start); f.recurrence = recurrence.applying(to: f.recurrence)
        f.earlyAlerts = earlyAlerts.applying(to: f.earlyAlerts, cleared: []) ?? []
        f.location = location.applying(to: f.location); f.contact = contact.applying(to: f.contact)
        f.url = url.applying(to: f.url); f.priority = priority.applying(to: f.priority, cleared: Priority.none) ?? .none
        f.flagged = flagged.applying(to: f.flagged, cleared: false) ?? false
        f.urgent = urgent.applying(to: f.urgent, cleared: false) ?? false
        f.completed = completed.applying(to: f.completed, cleared: false) ?? false
        f.tags = tags.applying(to: f.tags, cleared: []) ?? []
        f.parentID = parentID.applying(to: f.parentID); f.sectionID = sectionID.applying(to: f.sectionID)
        f.position = position.applying(to: f.position); f.assigneeID = assigneeID.applying(to: f.assigneeID)
        return f
    }
}
public struct ReminderDraft: Codable, Sendable, Equatable {
    public var fields: ReminderFields
    public var images: [ImageInput]
    public init(fields: ReminderFields, images: [ImageInput] = []) { self.fields = fields; self.images = images }
}
public struct ReminderQuery: Codable, Sendable, Equatable {
    public var text: String?
    public var list: String?
    public var smartList: String?
    public var section: String?
    public var includeCompleted: Bool = false
    public var flagged: Bool?
    public var urgent: Bool?
    public var repeating: Bool?
    public var hasLocation: Bool?
    public var assigneeID: String?
    public var tags: [String] = []
    public var dueOnOrAfter: ReminderDate?
    public var dueBefore: ReminderDate?
    public var limit: Int = 100
    public init() {}
}

public struct Member: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var isCurrentUser: Bool
    public init(id: String, name: String, isCurrentUser: Bool = false) {
        self.id = id; self.name = name; self.isCurrentUser = isCurrentUser
    }
}
public enum ListKind: String, Codable, Sendable { case standard, groceries }
public enum ListSort: String, Codable, Sendable { case manual, due, creation, priority, title }
public struct ListFields: Codable, Sendable, Equatable {
    public var name: String
    public var color: String?
    public var icon: String?
    public var groupID: String?
    public var pinned: Bool
    public var kind: ListKind
    public var sort: ListSort
    public var position: Position?
    public init(name: String, color: String? = nil, icon: String? = nil, groupID: String? = nil,
                pinned: Bool = false, kind: ListKind = .standard, sort: ListSort = .manual, position: Position? = nil) {
        self.name = name; self.color = color; self.icon = icon; self.groupID = groupID
        self.pinned = pinned; self.kind = kind; self.sort = sort; self.position = position
    }
}
public struct ReminderList: Codable, Sendable, Equatable {
    public var id: String
    public var fields: ListFields
    public var isDefault: Bool
    public var members: [Member]
    public init(id: String, fields: ListFields, isDefault: Bool = false, members: [Member] = []) {
        self.id = id; self.fields = fields; self.isDefault = isDefault; self.members = members
    }
}
public struct NamedEntity: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}
public struct Section: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var listID: String
    public var position: Position?
    public init(id: String, name: String, listID: String, position: Position? = nil) {
        self.id = id; self.name = name; self.listID = listID; self.position = position
    }
}
public struct Tag: Codable, Sendable, Equatable {
    public var name: String
    public var openCount: Int
    public var totalCount: Int
    public init(name: String, openCount: Int = 0, totalCount: Int = 0) {
        self.name = name; self.openCount = openCount; self.totalCount = totalCount
    }
}
public enum MatchMode: String, Codable, Sendable { case all, any }
public enum DateFilter: Codable, Sendable, Equatable {
    case none, any, overdue
    case range(from: CalendarDate?, before: CalendarDate?)
    case relative(past: Int, future: Int, unit: AlertUnit)
}
public enum LocationFilter: String, Codable, Sendable { case any, none, arriving, leaving, gettingInCar, gettingOutOfCar }
public enum SmartFilter: Codable, Sendable, Equatable {
    case tags([String], match: MatchMode)
    case date(DateFilter)
    case time(fromHour: Int, fromMinute: Int, toHour: Int, toMinute: Int)
    case priorities([Priority])
    case flagged(Bool)
    case lists([String])
    case location(LocationFilter)
    /// Read preservation only; the backend must not reinterpret unknown native payloads.
    case unknown(key: String, payload: Data)
}
public struct SmartList: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var color: String?
    public var icon: String?
    public var match: MatchMode
    public var filters: [SmartFilter]
    public init(id: String, name: String, color: String? = nil, icon: String? = nil,
                match: MatchMode = .all, filters: [SmartFilter] = []) {
        self.id = id; self.name = name; self.color = color; self.icon = icon; self.match = match; self.filters = filters
    }
}
public struct Catalog: Codable, Sendable, Equatable {
    public var lists: [ReminderList]
    public var groups: [NamedEntity]
    public var sections: [Section]
    public var tags: [Tag]
    public var smartLists: [SmartList]
    public var templates: [NamedEntity]
    public init(lists: [ReminderList] = [], groups: [NamedEntity] = [], sections: [Section] = [],
                tags: [Tag] = [], smartLists: [SmartList] = [], templates: [NamedEntity] = []) {
        self.lists = lists; self.groups = groups; self.sections = sections
        self.tags = tags; self.smartLists = smartLists; self.templates = templates
    }
}
