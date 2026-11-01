import Foundation
import ReminderKitShim
import ReminderCore

/// A single worker owns one backend. Public calls are serialized even if a caller
/// bypasses Operations; no private object or selector escapes ReminderKitShim.
public final class NativeReminderBackend: ReminderBackend {
    private let lock = NSRecursiveLock()
    private var bridge: RNBridge?
    private let openBridge: () throws -> RNBridge
    private let permission: () -> String

    public convenience init() {
        self.init(openBridge: { try RNBridge.open() }, permission: Self.authorizationStatus)
    }
    init(openBridge: @escaping () throws -> RNBridge, permission: @escaping () -> String) {
        self.openBridge = openBridge; self.permission = permission
    }
    public static func authorizationStatus() -> String {
        switch RNAuthorizationStatus() {
        case 0: "notDetermined"
        case 1: "restricted"
        case 2: "denied"
        case 3: "fullAccess"
        case 4: "writeOnly"
        default: "unavailable"
        }
    }
    /// Only setup calls this. No backend constructor or normal command requests access.
    public static func requestAuthorization() throws -> Bool {
        var error: NSError?
        let granted = RNRequestAuthorization(&error)
        if let error { throw failure(error) }
        return granted
    }
    /// Declaration of implementation scope, NOT a runtime probe or permission claim.
    public static func capabilities() -> [String] {
        ["implementation:ReminderKit-native", "liveVerification:priorSignedBuildOnly", "reminder:byID,find,create,sparseUpdate,complete,softDelete,restore",
         "catalog:lists,groups,sections,tags,customSmartLists,templates", "fields:dates,recurrence,earlyAlerts,location,vehicle,contact,url,images,joinedMemberAssignment",
         "smartFilters:tags,priorities,flagged,listsUnion,anyDate,civilDateRanges,oneDirectionRelativeDate,vehicle,noLocation",
         "listPosition:writeOnlyDirective",
         "unsupported:arbitraryTimeFilters,coordinateFreePlaceFilters,overdueOnlyFilter,unknownFilterEdits,clearManualPosition,multipleURLs,multipleRecurrenceRules",
         "save:localAcceptanceOnly", "deleted:toolOnlyJournal", "permissions:setupOnly"]
    }
    private func serialized<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        do { return try body() } catch { throw Self.failure(error) }
    }
    private func store() throws -> RNBridge {
        guard permission() == "fullAccess" else { throw Failure(.permission, "Reminders full access is required; run setup explicitly") }
        if let bridge { return bridge }
        let opened = try openBridge(); bridge = opened; return opened
    }
    static func failure(_ error: Error) -> Failure {
        if let failure = error as? Failure { return failure }
        let native = error as NSError
        let code: ErrorCode
        if native.domain == RNErrorDomain {
            switch native.code {
            case 1: code = .unsupported; case 3: code = .notFound; case 4: code = .invalidInput
            case 5: code = .outcomeUnknown; case 6: code = .permission; default: code = .backend
            }
        } else { code = .backend }
        return Failure(code, native.localizedDescription, affectedIDs: native.userInfo["affectedIDs"] as? [String] ?? [])
    }
    private func checkFeatures(_ features: [String]) throws {
        var error: NSError?
        guard RNPreflight(features, &error) else { throw Self.failure(error ?? NSError(domain: RNErrorDomain, code: 1)) }
    }
    public func checkSupport(for command: Command) throws {
        // Validate values first, then inspect command-specific Objective-C class
        // metadata. No store objects, prompts, requests or staged files are created.
        try serialized {
            var features: [String] = []
            switch command {
            case .create(let draft):
                features = ["reminder.create"] + Array(try Translation.creationFields(draft.fields).keys)
                for image in draft.images { _ = try ImageStaging.validate(image) }
                if !draft.images.isEmpty { features.append("addImages") }
            case .update(_, _, let patch):
                features = ["reminder.update"] + Array(try Translation.patch(patch).keys)
                for image in patch.addImages { _ = try ImageStaging.validate(image) }
                if !patch.addImages.isEmpty { features.append("addImages") }
            case .smartList(.create(let smart)), .smartList(.update(_, let smart)):
                _ = try SmartFilters.data(smart); _ = try Translation.color(smart.color)
                features = ["smart.update", "appearance"]
                if case .smartList(.create) = command { features.append("smart.create") }
            case .list(.create(let fields)), .list(.update(_, let fields)):
                _ = try Translation.listFields(fields); features = ["list.update", "appearance"]
                if case .list(.create) = command { features.append("list.create") }
            case .list(.delete): features = ["reminder.list", "list.delete"]
            case .list(.clearCompleted): features = ["reminder.list", "reminder.delete"]
            case .delete: features = ["reminder.delete"]
            case .restore: features = ["reminder.restore"]
            case .complete: features = ["reminder.update", "completed"]
            case .group(.create): features = ["group.create"]
            case .group(.rename): features = ["group.rename"]
            case .group(.delete): features = ["group.delete"]
            case .section(.create): features = ["section.create"]
            case .section(.rename): features = ["section.rename"]
            case .section(.move): features = ["section.move"]
            case .section(.delete): features = ["section.delete"]
            case .smartList(.delete): features = ["smart.delete"]
            case .template(.create): features = ["template.create"]
            case .template(.use): features = ["template.use"]
            case .template(.delete): features = ["template.delete"]
            case .tag: features = ["tags.read", "tags", "reminder.update"]
            case .catalog(true): features = ["tags.read"]
            case .find(let query): features = [query.smartList == nil ? "reminder.find" : "smart.find"]
            default: break
            }
            if !features.isEmpty { try checkFeatures(features) }
            // Resolved account capability checks are reads before mutationStarted.
            // Initial unresolved names defer to Core's normalized second preflight.
            if case .restore(_, let list) = command, let list, UUID(uuidString: list) != nil {
                try store().validateRecovery(forList: list)
            }
            if case .smartList(.create) = command { try store().validateSmartListCreation() }
            if case .tag(let action) = command {
                switch action { case .rename(let name, _), .delete(let name, _): try store().validateTag(name) }
            }
        }
    }
    private func rawReminder(_ id: String, concealed: Bool = false, imageBytes: Bool = false) throws -> [String: Any]? {
        try Translation.object(try store().reminder(id, concealed: concealed, imageBytes: imageBytes))
    }
    private func lookup(_ id: String) throws -> Reminder? {
        guard UUID(uuidString: id) != nil else { return nil } // Core then resolves an exact title.
        return try rawReminder(id).map(Translation.reminder)
    }
    private func requireReminder(_ id: String) throws -> Reminder {
        guard let reminder = try lookup(id) else { throw Failure(.notFound, "Reminder not found: \(id)") }
        return reminder
    }
    public func reminder(id: String) throws -> Reminder? { try serialized { try lookup(id) } }
    public func image(reminderID: String, imageID: String) throws -> ImageInput {
        try serialized {
            guard let raw = try rawReminder(reminderID, imageBytes: true) else { throw Failure(.notFound, "Reminder not found") }
            let images: [[String: Any]] = try Translation.value(raw, "images")
            guard let image = images.first(where: { ($0["id"] as? String)?.caseInsensitiveCompare(imageID) == .orderedSame }) else {
                throw Failure(.notFound, "Image attachment not found")
            }
            return try ImageInput(fileName: Translation.value(image, "fileName"), contentType: Translation.value(image, "type"), bytes: Translation.value(image, "data"))
        }
    }
    public func restorableState(id: String) throws -> RestorableState {
        try serialized {
            if try rawReminder(id) != nil { return .active }
            return try rawReminder(id, concealed: true) == nil ? .absent : .restorable
        }
    }
    private func readReminders(listID: String? = nil, identifiers: [String]? = nil) throws -> [Reminder] {
        try store().reminders(inList: listID, identifiers: identifiers).map(Translation.reminder)
    }
    public func catalog(includeTags: Bool) throws -> Catalog {
        try serialized {
            let native = try store(), rawLists = try native.lists(), defaultID = try native.defaultList()
            let lists = try rawLists.map { try Translation.list($0, defaultID: defaultID) }
            let sections: [Section] = try rawLists.flatMap { raw in
                let entries: [[String: Any]] = try Translation.value(raw, "sections")
                return try entries.map { try Section(id: Translation.value($0, "id"), name: Translation.value($0, "name"), listID: Translation.value($0, "listID"), position: Translation.position($0["position"] as? [String: Any])) }
            }
            // Explicit metadata projections do not enumerate reminders at all.
            // A requested tag catalog scans only hashtags/completed flags in ObjC.
            let tags = includeTags ? try native.tagCounts().map { try Tag(name: Translation.value($0, "name"),
                openCount: Translation.value($0, "openCount"), totalCount: Translation.value($0, "totalCount")) } : []
            return try Catalog(lists: lists, groups: native.groups().map(named), sections: sections,
                tags: tags,
                smartLists: native.smartLists().map(SmartFilters.decode), templates: native.templates().map(named))
        }
    }
    private func named(_ raw: [String: Any]) throws -> NamedEntity {
        try NamedEntity(id: Translation.value(raw, "id"), name: Translation.value(raw, "name"),
            color: Translation.color(raw["color"] as? [String: Any]), icon: raw["icon"] as? String)
    }
    public func reminders(listID: String?) throws -> [Reminder] {
        try serialized { try checkFeatures(["reminder.list"]); return try readReminders(listID: listID) }
    }
    public func reminders(matchingTitle title: String) throws -> [Reminder] {
        try serialized { try checkFeatures(["reminder.title"]); return try store().reminders(matchingTitle: title).map(Translation.reminder) }
    }
    public func find(_ query: ReminderQuery) throws -> [Reminder] {
        try serialized {
            try Validation.query(query)
            if let smart = query.smartList {
                let ids = try store().contents(ofSmartList: smart, includeCompleted: query.includeCompleted)
                return try readReminders(identifiers: Array(ids.dropFirst(query.offset).prefix(query.limit)))
            }
            var criteria: [[String: Any]] = []
            if let text = query.text {
                let matching: Int
                switch query.matching ?? .word { case .exact: matching = 0; case .prefix: matching = 1; case .word: matching = 2 }
                criteria.append(["base": "textualField", "arg0": text, "arg1": matching])
            }
            if let list = query.list {
                criteria.append(["base": "listID", "arg0": ["entityName": "REMList", "uuid": list], "arg1": ["includeForSiri": [:]]])
            }
            for (name, value) in [("isCompleted", query.completed ?? (query.includeCompleted ? nil : false)),
                                  ("isFlagged", query.flagged), ("isUrgentForCurrentUser", query.urgent),
                                  ("isRecurrent", query.repeating), ("hasLocation", query.hasLocation), ("hasDueDate", query.hasDueDate)] {
                if let value { criteria.append(["base": name, "arg0": value]) }
            }
            return try store().searchReminders(criteria: criteria, limit: query.limit, offset: query.offset).map(Translation.reminder)
        }
    }
    private static func same(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) { case (nil, nil): true; case (.some(let a), .some(let b)): a.caseInsensitiveCompare(b) == .orderedSame; default: false }
    }
    /// Everything after a confirmed native save is uncertain if readback fails.
    /// A lost readback is never represented as a definite no-write error.
    private func readback<T>(ids: [String], _ body: () throws -> T) throws -> T {
        do { return try body() }
        catch {
            let cause = Self.failure(error)
            throw Failure(.outcomeUnknown, "Native save accepted locally, but confirmation failed: \(cause.message)", underlyingCode: cause.code, affectedIDs: ids)
        }
    }
    private func verifyImages(_ staged: [ImageInput], lease: ImageStaging?, ownerID: String, existingIDs: Set<String>) throws {
        guard let lease else { return }
        guard let raw = try rawReminder(ownerID) else { throw Failure(.backend, "Saved image owner disappeared") }
        let images: [[String: Any]] = try Translation.value(raw, "images")
        try ImageStaging.verifyConsumed(staged, nativeImages: images, existingIDs: existingIDs, directory: lease.directory)
    }
    /// Shared save/receipt/attachment lifecycle for creates and sparse updates.
    /// Snapshot request-owned identities before any bridge read can reset them.
    private func saveReminder(changes: [String: Any], images: [ImageInput], existingIDs: Set<String> = [],
                              save: (RNBridge, [String: Any]) throws -> String,
                              confirm: ([Reminder], Set<String>) throws -> Void = { _, _ in }) throws -> MutationResult {
        let native = try store(), staging = images.isEmpty ? nil : try ImageStaging(images)
        var changes = changes; changes["addImages"] = staging?.images
        let id: String
        do { id = try save(native, changes) }
        catch {
            if Self.failure(error).code != .outcomeUnknown { try? staging?.release() }
            throw error
        }
        let receipt = Array(Set(native.lastSavedReminderIDs + [id])).sorted()
        let introduced = Set(native.lastIntroducedReminderIDs.map { $0.uppercased() })
        return try readback(ids: receipt) {
            let changed = try readReminders(identifiers: receipt)
            try confirm(changed, introduced)
            try verifyImages(images, lease: staging, ownerID: id, existingIDs: existingIDs); try staging?.release()
            return MutationResult(affectedIDs: receipt, reminders: changed)
        }
    }
    public func createReminder(_ draft: ReminderDraft) throws -> MutationResult {
        try serialized {
            var changes = try Translation.creationFields(draft.fields)
            changes.removeValue(forKey: "listID") // Native creation already places it in this list.
            return try saveReminder(changes: changes, images: draft.images) { native, fields in
                try native.createReminder(inList: draft.fields.listID, title: draft.fields.title, changes: fields)
            }
        }
    }
    public func updateReminder(id: String, patch: ReminderPatch) throws -> MutationResult {
        try serialized {
            let old = try requireReminder(id), projected = try patch.applying(to: old.fields)
            return try saveReminder(changes: Translation.patch(patch), images: patch.addImages, existingIDs: Set(old.images.map(\.id)), save: { native, fields in
                try native.updateReminder(id, changes: fields); return id
            }, confirm: { changed, introduced in
                if old.fields.recurrence != nil && !old.fields.completed && projected.completed {
                    guard changed.contains(where: { introduced.contains($0.id.uppercased()) && $0.id.caseInsensitiveCompare(id) != .orderedSame && $0.fields.completed && $0.fields.recurrence == nil && $0.fields.title == projected.title }) else {
                        throw Failure(.backend, "Native recurrence save did not expose a request-owned completed-copy receipt")
                    }
                }
            })
        }
    }
    public func deleteReminders(ids: [String]) throws -> MutationResult {
        try serialized {
            try store().softDeleteReminders(ids)
            return try readback(ids: ids) {
                for id in ids {
                    guard try restorableState(id: id) == .restorable else { throw Failure(.backend, "Soft-deleted reminder not confirmed restorable: \(id)") }
                }
                return MutationResult(affectedIDs: ids)
            }
        }
    }
    public func restoreReminder(id: String, listID: String, knownChildIDs: [String], parentID: String?) throws -> MutationResult {
        try serialized {
            guard let root = try rawReminder(id, concealed: true) else { throw Failure(.notFound, "Restorable root not found") }
            let nativeParent = root["parentID"] as? String
            if let nativeParent, let parentID, !Self.same(nativeParent, parentID) {
                throw Failure(.conflict, "Deleted reminder's parent differs from journal evidence")
            }
            let expectedParent = parentID ?? nativeParent
            let nativeChildren: [String] = try Translation.value(root, "childIDs")
            let children = Set((knownChildIDs + nativeChildren).map { $0.uppercased() }).sorted()
            let ids = [id] + children
            let native = try store()
            try native.restoreReminders(ids, toList: listID, parentID: expectedParent)
            let receipt = Array(Set(ids + native.lastSavedReminderIDs)).sorted()
            return try readback(ids: receipt) {
                let reminders = try readReminders(identifiers: receipt)
                for reminder in reminders {
                    if expectedParent.map({ reminder.id.caseInsensitiveCompare($0) == .orderedSame }) == true {
                        guard reminder.fields.listID.caseInsensitiveCompare(listID) == .orderedSame, reminder.fields.parentID == nil,
                              reminder.childIDs.contains(where: { $0.caseInsensitiveCompare(id) == .orderedSame }) else {
                            throw Failure(.backend, "Touched restore parent has inconsistent relationship readback")
                        }
                        continue
                    }
                    guard ids.contains(where: { $0.caseInsensitiveCompare(reminder.id) == .orderedSame }),
                          reminder.fields.listID.caseInsensitiveCompare(listID) == .orderedSame,
                          (reminder.id.caseInsensitiveCompare(id) == .orderedSame ? Self.same(reminder.fields.parentID, expectedParent) : reminder.fields.parentID?.caseInsensitiveCompare(id) == .orderedSame) else {
                        throw Failure(.backend, "Restore readback has inconsistent list/parent links")
                    }
                }
                let restoredRoot = try requireReminder(id)
                guard Set(restoredRoot.childIDs.map { $0.uppercased() }) == Set(children) else {
                    throw Failure(.backend, "Restored root's children differ from journal evidence")
                }
                return MutationResult(affectedIDs: receipt, reminders: reminders)
            }
        }
    }
    private func listReceipt(_ id: String) throws -> MutationResult {
        let native = try store(), reminderIDs = native.lastSavedReminderIDs
        return try readback(ids: [id] + reminderIDs) {
            let defaultID = try native.defaultList()
            guard let raw = try native.lists().first(where: { ($0["id"] as? String)?.caseInsensitiveCompare(id) == .orderedSame }) else { throw Failure(.backend, "Saved list missing on readback") }
            return MutationResult(affectedIDs: [id] + reminderIDs, reminders: try readReminders(identifiers: reminderIDs), lists: [try Translation.list(raw, defaultID: defaultID)])
        }
    }
    public func list(_ action: ListAction) throws -> MutationResult {
        try serialized {
            let native = try store()
            switch action {
            case .create(let fields): return try listReceipt(native.createList(fields.name, changes: Translation.listFields(fields)))
            case .update(let id, let fields): try native.updateList(id, changes: Translation.listFields(fields)); return try listReceipt(id)
            case .delete(let id, let confirmed):
                guard confirmed else { throw Failure(.invalidInput, "List deletion needs confirmation") }
                let affected = try readReminders(listID: id).map(\.id)
                try native.deleteList(id); return MutationResult(affectedIDs: [id] + affected)
            case .clearCompleted(let id, let confirmed):
                guard confirmed else { throw Failure(.invalidInput, "Clear-completed needs confirmation") }
                // Operations has already journaled the same expanded selection.
                // A parent and every child enter one request/save, never one save per row.
                let all = try readReminders(listID: id)
                var selected = Set(all.filter(\.fields.completed).map(\.id))
                for item in all where selected.contains(item.id) { selected.formUnion(item.childIDs) }
                return try deleteReminders(ids: selected.sorted())
            }
        }
    }
    public func group(_ action: GroupAction) throws -> MutationResult {
        try serialized {
            let native = try store()
            switch action {
            case .create(let name): return MutationResult(affectedIDs: [try native.createGroup(name)])
            case .rename(let id, let name): try native.renameGroup(id, name: name); return MutationResult(affectedIDs: [id])
            case .delete(let id, let confirmed):
                guard confirmed else { throw Failure(.invalidInput, "Group deletion needs confirmation") }
                try native.deleteGroup(id); return MutationResult(affectedIDs: [id])
            }
        }
    }
    public func section(_ action: SectionAction) throws -> MutationResult {
        try serialized {
            let native = try store()
            switch action {
            case .create(let list, let name): return MutationResult(affectedIDs: [try native.createSection(name, list: list)])
            case .rename(let list, let id, let name): try native.updateSection(id, list: list, changes: ["name": name]); return MutationResult(affectedIDs: [id])
            case .move(let list, let id, let position): try native.updateSection(id, list: list, changes: ["position": Translation.position(position)]); return MutationResult(affectedIDs: [id])
            case .delete(let list, let id, let confirmed):
                guard confirmed else { throw Failure(.invalidInput, "Section deletion needs confirmation") }
                try native.deleteSection(id, list: list); return MutationResult(affectedIDs: [id])
            }
        }
    }
    public func tag(_ action: TagAction) throws -> MutationResult {
        try serialized {
            let from: String, replacement: String?
            switch action {
            case .rename(let name, let new): from = name; replacement = new
            case .delete(let name, let confirmed):
                guard confirmed else { throw Failure(.invalidInput, "Tag deletion needs confirmation") }
                from = name; replacement = nil
            }
            let native = try store()
            let selected = try native.replaceTag(from, replacement: replacement)
            let affected = native.lastSavedReminderIDs
            return try readback(ids: Array(Set(selected + affected)).sorted()) {
                guard Set(selected.map { $0.uppercased() }) == Set(affected.map { $0.uppercased() }) else { throw Failure(.backend, "Native tag receipt does not cover the exact request-selected rows") }
                return MutationResult(affectedIDs: affected, reminders: try readReminders(identifiers: affected))
            }
        }
    }
    public func smartList(_ action: SmartListAction) throws -> MutationResult {
        try serialized {
            let native = try store()
            func fields(_ smart: SmartList) throws -> [String: Any] {
                ["name": smart.name, "filterData": try SmartFilters.data(smart), "color": try Translation.color(smart.color) as Any? ?? NSNull(), "icon": smart.icon as Any? ?? NSNull()]
            }
            switch action {
            case .create(let smart): return MutationResult(affectedIDs: [try native.createSmartList(smart.name, changes: fields(smart))])
            case .update(let id, let smart): try native.updateSmartList(id, changes: fields(smart)); return MutationResult(affectedIDs: [id])
            case .delete(let id, let confirmed):
                guard confirmed else { throw Failure(.invalidInput, "Smart-list deletion needs confirmation") }
                try native.deleteSmartList(id); return MutationResult(affectedIDs: [id])
            }
        }
    }
    public func template(_ action: TemplateAction) throws -> MutationResult {
        try serialized {
            let native = try store()
            switch action {
            case .create(let name, let list, let completed): return MutationResult(affectedIDs: [try native.createTemplate(name, list: list, includeCompleted: completed)])
            case .use(let id, let name): return try listReceipt(native.useTemplate(id, name: name))
            case .delete(let id, let confirmed):
                guard confirmed else { throw Failure(.invalidInput, "Template deletion needs confirmation") }
                try native.deleteTemplate(id); return MutationResult(affectedIDs: [id])
            }
        }
    }
}
