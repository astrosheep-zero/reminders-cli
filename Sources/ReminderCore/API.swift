import Foundation

public enum ListAction: Codable, Sendable, Equatable {
    case create(ListFields)
    case update(String, ListPatch, clear: [ListClear] = [])
    case clearCompleted(String, confirmed: Bool)
    case delete(String, confirmed: Bool)
}
public enum GroupAction: Codable, Sendable, Equatable {
    case create(String), rename(String, name: String), delete(String, confirmed: Bool)
}
public enum SectionAction: Codable, Sendable, Equatable {
    case create(list: String, name: String)
    case update(list: String, section: String, patch: SectionPatch)
    case delete(list: String, section: String, confirmed: Bool)
}
public enum TagAction: Codable, Sendable, Equatable {
    case rename(String, name: String), delete(String, confirmed: Bool)
}
public enum SmartListAction: Codable, Sendable, Equatable {
    case create(SmartList), update(String, SmartList), delete(String, confirmed: Bool)
}
public enum TemplateAction: Codable, Sendable, Equatable {
    case create(name: String, list: String, includeCompleted: Bool)
    case use(String, newListName: String?)
    case delete(String, confirmed: Bool)
}
public enum Command: Codable, Sendable, Equatable {
    case find(ReminderQuery)
    case show(String)
    case create(ReminderDraft)
    case update(id: String, version: String, patch: ReminderPatch)
    case complete(id: String, version: String, completed: Bool)
    case delete(id: String, version: String)
    case restore(id: String, list: String?)
    case deleted
    case catalog(CatalogScope, list: String? = nil)
    case image(reminderID: String, imageID: String)
    case list(ListAction)
    case group(GroupAction)
    case section(SectionAction)
    case tag(TagAction)
    case smartList(SmartListAction)
    case template(TemplateAction)
}
public enum ErrorCode: String, Codable, Sendable {
    case invalidInput, notFound, ambiguous, conflict, permission, sandbox, unsupported, outcomeUnknown, backend, io, `internal`
    public var exitStatus: Int {
        switch self {
        case .invalidInput: 1
        case .notFound, .ambiguous, .conflict: 2
        case .permission, .sandbox: 3
        case .unsupported: 4
        case .outcomeUnknown: 5
        case .backend, .io, .internal: 6
        }
    }
}
public struct Failure: Error, Codable, Sendable, Equatable {
    public var code: ErrorCode
    public var message: String
    /// Present when a failure occurred after entering a mutating backend method.
    public var underlyingCode: ErrorCode?
    public var affectedIDs: [String]
    public init(_ code: ErrorCode, _ message: String, underlyingCode: ErrorCode? = nil, affectedIDs: [String] = []) {
        self.code = code; self.message = message; self.underlyingCode = underlyingCode; self.affectedIDs = affectedIDs
    }
}
/// Backend must report every known affected ID, including children and recurring completed copies.
public struct MutationResult: Codable, Sendable, Equatable {
    public var affectedIDs: [String]
    public var reminders: [Reminder]
    public var lists: [ReminderList]
    public var count: Int { affectedIDs.count }
    public init(affectedIDs: [String], reminders: [Reminder] = [], lists: [ReminderList] = []) {
        self.affectedIDs = affectedIDs; self.reminders = reminders; self.lists = lists
    }
}
public struct DeletedResult: Codable, Sendable, Equatable {
    public enum Scope: String, Codable, Sendable { case toolOnly }
    public let scope: Scope
    public var entries: [DeletionEntry]
    public init(entries: [DeletionEntry]) { self.scope = .toolOnly; self.entries = entries }
}
public enum OperationResult: Codable, Sendable, Equatable {
    case reminders([Reminder]), catalog(Catalog, scope: CatalogScope = .all), mutation(MutationResult), deleted(DeletedResult), image(ImageInput)
}
public struct ExecutionResult: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case ok, failed, unknown }
    public var status: Status
    public var result: OperationResult?
    public var error: Failure?
    public var warnings: [String]
    public init(status: Status, result: OperationResult? = nil, error: Failure? = nil, warnings: [String] = []) {
        self.status = status; self.result = result; self.error = error; self.warnings = warnings
    }
}
public enum RestorableState: String, Codable, Sendable { case active, restorable, absent }

/// Synchronous and called only through serialized Operations. No save is allowed in read/preflight methods.
/// Native implementations must use direct by-ID lookups where available and must never clone/delete to move.
public protocol ReminderBackend: AnyObject {
    /// Must reject unsupported commands/fields BEFORE mutationStarted. Never returns fabricated empty success.
    func checkSupport(for command: Command) throws
    func catalog(_ scopes: Set<CatalogScope>, listID: String?) throws -> Catalog
    func find(_ query: ReminderQuery) throws -> [Reminder]
    /// Exhaustive active reminders, including completed and children; nil selects all lists. Never silently truncate.
    func reminders(listID: String?) throws -> [Reminder]
    /// Complete native title-predicate results, including completed reminders; never silently truncate.
    func reminders(matchingTitle: String) throws -> [Reminder]
    func reminder(id: String) throws -> Reminder?
    func image(reminderID: String, imageID: String) throws -> ImageInput
    func restorableState(id: String) throws -> RestorableState
    func createReminder(_ draft: ReminderDraft) throws -> MutationResult
    /// Apply ONLY non-absent fields; do not rewrite native-only or untouched state.
    func updateReminder(id: String, patch: ReminderPatch) throws -> MutationResult
    /// One native request/save must include all IDs; never loop and individually save children.
    func deleteReminders(ids: [String]) throws -> MutationResult
    /// Restores root + saved children + any additional native children using the saved parent evidence.
    func restoreReminder(id: String, listID: String, knownChildIDs: [String], parentID: String?) throws -> MutationResult
    func createList(_ fields: ListFields) throws -> MutationResult
    func updateList(id: String, fields: ListFields) throws -> MutationResult
    func deleteList(id: String) throws -> MutationResult
    func group(_ action: GroupAction) throws -> MutationResult
    func section(_ action: SectionAction) throws -> MutationResult
    func tag(_ action: TagAction) throws -> MutationResult
    func smartList(_ action: SmartListAction) throws -> MutationResult
    func template(_ action: TemplateAction) throws -> MutationResult
}

/// Defaults fail closed. Override checkSupport along with the methods actually supported.
public extension ReminderBackend {
    func checkSupport(for command: Command) throws { throw Failure(.unsupported, "Backend does not support this command") }
    func catalog(_ scopes: Set<CatalogScope>) throws -> Catalog { try catalog(scopes, listID: nil) }
    func catalog(_ scopes: Set<CatalogScope>, listID: String?) throws -> Catalog { throw Failure(.unsupported, "Catalog unavailable") }
    func find(_ query: ReminderQuery) throws -> [Reminder] { throw Failure(.unsupported, "Find unavailable") }
    func reminders(listID: String?) throws -> [Reminder] { throw Failure(.unsupported, "Exhaustive reminder read unavailable") }
    func reminders(matchingTitle: String) throws -> [Reminder] { throw Failure(.unsupported, "Title lookup unavailable") }
    func reminder(id: String) throws -> Reminder? { throw Failure(.unsupported, "Reminder lookup unavailable") }
    func image(reminderID: String, imageID: String) throws -> ImageInput { throw Failure(.unsupported, "Image read unavailable") }
    func restorableState(id: String) throws -> RestorableState { throw Failure(.unsupported, "Recovery lookup unavailable") }
    func createReminder(_ draft: ReminderDraft) throws -> MutationResult { throw Failure(.unsupported, "Create unavailable") }
    func updateReminder(id: String, patch: ReminderPatch) throws -> MutationResult {
        throw Failure(.unsupported, "Update unavailable")
    }
    func deleteReminders(ids: [String]) throws -> MutationResult { throw Failure(.unsupported, "Delete unavailable") }
    func restoreReminder(id: String, listID: String, knownChildIDs: [String], parentID: String?) throws -> MutationResult {
        throw Failure(.unsupported, "Restore unavailable")
    }
    func createList(_ fields: ListFields) throws -> MutationResult { throw Failure(.unsupported, "List creation unavailable") }
    func updateList(id: String, fields: ListFields) throws -> MutationResult { throw Failure(.unsupported, "List update unavailable") }
    func deleteList(id: String) throws -> MutationResult { throw Failure(.unsupported, "List deletion unavailable") }
    func group(_ action: GroupAction) throws -> MutationResult { throw Failure(.unsupported, "Group mutation unavailable") }
    func section(_ action: SectionAction) throws -> MutationResult { throw Failure(.unsupported, "Section mutation unavailable") }
    func tag(_ action: TagAction) throws -> MutationResult { throw Failure(.unsupported, "Tag mutation unavailable") }
    func smartList(_ action: SmartListAction) throws -> MutationResult { throw Failure(.unsupported, "Smart list mutation unavailable") }
    func template(_ action: TemplateAction) throws -> MutationResult { throw Failure(.unsupported, "Template mutation unavailable") }
}
