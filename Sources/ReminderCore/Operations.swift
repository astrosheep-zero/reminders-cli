import Foundation

/// Serializes this engine instance; it is NOT a global or cross-device transaction.
/// Callbacks/backends must not re-enter execute. No automatic retry is ever performed.
public final class Operations: @unchecked Sendable {
    private let backend: any ReminderBackend
    private let journal: DeletionJournal
    private let onMutation: () throws -> Void
    private let lock = NSLock()
    private var started = false
    private var evidence: MutationResult?
    public init(backend: any ReminderBackend, journalURL: URL = DeletionJournal.defaultURL,
                onMutation: @escaping () throws -> Void = {}) {
        self.backend = backend; self.journal = DeletionJournal(url: journalURL); self.onMutation = onMutation
    }
    public func execute(_ command: Command) -> ExecutionResult {
        lock.lock(); defer { lock.unlock() }
        started = false; evidence = nil
        do {
            try validateInput(command)
            try backend.checkSupport(for: command)
            return ExecutionResult(status: .ok, result: try run(command))
        } catch {
            let failure = (error as? Failure) ?? Failure(.backend, String(describing: error))
            if started {
                let ids = Array(Set((evidence?.affectedIDs ?? []) + failure.affectedIDs)).sorted()
                return ExecutionResult(status: .unknown, result: evidence.map(OperationResult.mutation),
                    error: Failure(.outcomeUnknown, failure.message,
                                   underlyingCode: failure.underlyingCode ?? failure.code, affectedIDs: ids),
                    warnings: ["Mutation may have been accepted locally; do not automatically retry."])
            }
            return ExecutionResult(status: failure.code == .outcomeUnknown ? .unknown : .failed, error: failure)
        }
    }
    private func mutate(_ body: () throws -> MutationResult) throws -> OperationResult {
        try onMutation()
        started = true
        let result = try body()
        evidence = result
        return .mutation(result)
    }
    private func io<T>(_ body: () throws -> T) throws -> T {
        do { return try body() }
        catch let failure as Failure { throw failure }
        catch { throw Failure(.io, "Deletion journal: \(error)") }
    }
    private func run(_ command: Command) throws -> OperationResult {
        switch command {
        case .catalog: return .catalog(try backend.catalog())
        case .find(var query):
            if query.list != nil || query.smartList != nil || query.section != nil {
                let catalog = try backend.catalog()
                if let list = query.list { query.list = try resolveList(list, catalog).id }
                if let smart = query.smartList { query.smartList = try resolve(smart, catalog.smartLists.map { ($0.id, $0.name) }) }
                if let section = query.section {
                    query.section = try resolve(section, catalog.sections.filter { query.list == nil || same($0.listID, query.list!) }.map { ($0.id, $0.name) })
                }
            }
            return .reminders(try backend.find(query))
        case .show(let reference): return .reminders([try reminder(reference)])
        case .image(let reference, let imageID):
            let item = try reminder(reference)
            guard let image = item.images.first(where: { same($0.id, imageID) }) else { throw Failure(.notFound, "Image not found") }
            return .image(try backend.image(reminderID: item.id, imageID: image.id))
        case .create(var draft):
            let catalog = try backend.catalog()
            if draft.fields.listID.isEmpty {
                if let parent = draft.fields.parentID { draft.fields.listID = try reminder(parent).fields.listID }
                else {
                    let defaults = catalog.lists.filter(\.isDefault)
                    guard defaults.count == 1 else { throw Failure(defaults.isEmpty ? .notFound : .ambiguous, "No unique default list") }
                    draft.fields.listID = defaults[0].id
                }
            }
            try resolveFields(&draft.fields, catalog: catalog)
            try Validation.fields(draft.fields, images: draft.images)
            try relationships(draft.fields, current: nil)
            // Recheck support with normalized values too (resolved list/account can affect capabilities).
            try backend.checkSupport(for: .create(draft))
            return try mutate { try backend.createReminder(draft) }
        case .update(let reference, let version, let patch):
            let current = try reminder(reference)
            try check(current, version)
            var fields = try patch.applying(to: current.fields)
            try resolveFields(&fields, catalog: backend.catalog())
            try Validation.fields(fields, images: patch.addImages)
            guard patch.removeImageIDs.allSatisfy({ id in current.images.contains { same($0.id, id) } }) else {
                throw Failure(.notFound, "Image to remove not found")
            }
            try relationships(fields, current: current)
            var resolved = patch
            resolved.removeImageIDs = patch.removeImageIDs.map { id in current.images.first { same($0.id, id) }!.id }
            if case .set = patch.listID { resolved.listID = .set(fields.listID) }
            if case .set = patch.parentID, let id = fields.parentID { resolved.parentID = .set(id) }
            if case .set = patch.sectionID, let id = fields.sectionID { resolved.sectionID = .set(id) }
            if case .set = patch.assigneeID, let id = fields.assigneeID { resolved.assigneeID = .set(id) }
            if case .set = patch.position, let position = fields.position { resolved.position = .set(position) }
            try backend.checkSupport(for: .update(id: current.id, version: version, patch: resolved))
            // Still an optimistic read/check/save, not atomic compare-and-swap.
            try recheck(current)
            return try mutate { try backend.updateReminder(id: current.id, patch: resolved) }
        case .complete(let reference, let version, let completed):
            var patch = ReminderPatch(); patch.completed = .set(completed)
            return try run(.update(id: reference, version: version, patch: patch))
        case .delete(let reference, let version):
            let root = try reminder(reference); try check(root, version)
            try backend.checkSupport(for: .delete(id: root.id, version: version))
            let records = try deletionTree(root)
            return try deleting(records) { try backend.deleteReminders(ids: records.map(\.id)) }
        case .deleted: return try deleted()
        case .restore(let reference, let target): return try restore(reference, target: target)
        case .list(let action): return try list(action)
        case .group(let action): return try group(action)
        case .section(let action): return try section(action)
        case .tag(let action):
            let catalog = try backend.catalog()
            let name: String
            switch action { case .rename(let old, _), .delete(let old, _): name = old }
            guard catalog.tags.contains(where: { $0.name == name }) else { throw Failure(.notFound, "Tag not found") }
            return try mutate { try backend.tag(action) }
        case .smartList(let action): return try smartList(action)
        case .template(let action): return try template(action)
        }
    }
    private func same(_ lhs: String, _ rhs: String) -> Bool { lhs.caseInsensitiveCompare(rhs) == .orderedSame }
    private func same(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) { case (nil, nil): true; case (.some(let lhs), .some(let rhs)): same(lhs, rhs); default: false }
    }
    private func resolve(_ input: String, _ candidates: [(String, String)]) throws -> String {
        let ids = candidates.filter { same($0.0, input) }
        let matches = ids.isEmpty ? candidates.filter { $0.1 == input } : ids
        guard matches.count == 1 else { throw Failure(matches.isEmpty ? .notFound : .ambiguous, "No unique match for \(input)") }
        return matches[0].0
    }
    private func resolveList(_ input: String, _ catalog: Catalog) throws -> ReminderList {
        let id = try resolve(input, catalog.lists.map { ($0.id, $0.fields.name) })
        return catalog.lists.first { $0.id == id }!
    }
    private func reminder(_ input: String) throws -> Reminder {
        // Backend guarantees case-insensitive ID lookup. No whole-account scan is imposed for IDs.
        if let item = try backend.reminder(id: input) { return item }
        if UUID(uuidString: input) != nil { throw Failure(.notFound, "Reminder not found: \(input)") }
        var query = ReminderQuery(); query.text = input; query.includeCompleted = true; query.limit = Int.max
        let matches = try backend.find(query).filter { $0.fields.title == input }
        guard matches.count == 1 else { throw Failure(matches.isEmpty ? .notFound : .ambiguous, "No unique reminder named \(input)") }
        return matches[0]
    }
    private func byID(_ id: String) throws -> Reminder {
        guard let item = try backend.reminder(id: id) else { throw Failure(.notFound, "Reminder not found: \(id)") }
        return item
    }
    private func check(_ item: Reminder, _ version: String) throws {
        guard try item.version() == version else { throw Failure(.conflict, "Reminder changed: \(item.id)") }
    }
    private func recheck(_ item: Reminder) throws { try check(byID(item.id), item.version()) }
    private func resolveFields(_ fields: inout ReminderFields, catalog: Catalog) throws {
        let list = try resolveList(fields.listID, catalog); fields.listID = list.id
        if let parent = fields.parentID { fields.parentID = try reminder(parent).id }
        if let section = fields.sectionID {
            fields.sectionID = try resolve(section, catalog.sections.filter { same($0.listID, list.id) }.map { ($0.id, $0.name) })
        }
        if let position = fields.position { fields.position = replacing(position, with: try byID(position.neighborID).id) }
        if let member = fields.assigneeID {
            let candidates = member == "me" ? list.members.filter(\.isCurrentUser) : list.members
            fields.assigneeID = try resolve(member == "me" && candidates.count == 1 ? candidates[0].id : member,
                                            candidates.map { ($0.id, $0.name) })
        }
    }
    private func relationships(_ fields: ReminderFields, current: Reminder?) throws {
        if let current, !same(current.fields.listID, fields.listID), !current.childIDs.isEmpty {
            throw Failure(.invalidInput, "Cannot move a parent with children")
        }
        try validateParent(id: current?.id, parentID: fields.parentID, listID: fields.listID,
                           hasChildren: !(current?.childIDs.isEmpty ?? true))
        if let position = fields.position {
            let neighbor = try byID(position.neighborID)
            guard current.map({ !same($0.id, neighbor.id) }) ?? true,
                  same(neighbor.fields.listID, fields.listID), same(neighbor.fields.sectionID, fields.sectionID),
                  same(neighbor.fields.parentID, fields.parentID) else {
                throw Failure(.invalidInput, "Order neighbor must be distinct and in the same list, section and parent")
            }
        }
    }
    /// Matching a saved parent ID alone is not relationship verification: read the active parent.
    private func validateParent(id: String?, parentID: String?, listID: String, hasChildren: Bool) throws {
        guard let parentID else { return }
        guard id.map({ !same($0, parentID) }) ?? true else { throw Failure(.invalidInput, "Cannot parent a reminder to itself") }
        let parent = try byID(parentID)
        guard parent.fields.parentID == nil, same(parent.fields.listID, listID), !hasChildren else {
            throw Failure(.invalidInput, "Parent must be top-level in the same list; nesting is limited to one level")
        }
    }
    private func deletionTree(_ root: Reminder) throws -> [Reminder] {
        var records = [root]
        for id in root.childIDs {
            let child = try byID(id)
            guard child.fields.parentID.map({ same($0, root.id) }) == true,
                  same(child.fields.listID, root.fields.listID), child.childIDs.isEmpty else {
                throw Failure(.conflict, "Child relationships changed")
            }
            records.append(child)
        }
        guard Set(records.map { $0.id.lowercased() }).count == records.count else { throw Failure(.conflict, "Duplicate deletion IDs") }
        return records
    }
    private func deleting(_ records: [Reminder], body: () throws -> MutationResult) throws -> OperationResult {
        let now = Date()
        try io { try journal.transaction { entries in
            for item in records {
                entries.removeAll { same($0.id, item.id) }
                entries.append(DeletionEntry(id: item.id, title: item.fields.title, listID: item.fields.listID,
                                            parentID: item.fields.parentID, time: now, state: .pending))
            }
        } }
        // The journal is intentionally retained even if this last optimistic check fails.
        for item in records { try recheck(item) }
        let result = try mutate(body)
        try io { try journal.transaction { entries in
            for index in entries.indices where records.contains(where: { same($0.id, entries[index].id) }) {
                // A newer process's deletion intent must not be overwritten by an older completion.
                if entries[index].time == now { entries[index].state = .confirmed }
            }
        } }
        return result
    }
    private func deleted() throws -> OperationResult {
        let entries = try io { try journal.transaction { entries in
            var reconciled: [DeletionEntry] = []
            for var entry in entries {
                let state: RestorableState
                do { state = try backend.restorableState(id: entry.id) }
                catch let failure as Failure { throw failure }
                catch { throw Failure(.backend, String(describing: error)) }
                switch state {
                case .restorable: entry.state = .confirmed; reconciled.append(entry)
                case .active:
                    // Active pending means interrupted BEFORE deletion; keep intent visible.
                    if entry.state == .pending { reconciled.append(entry) }
                case .absent: break // successful by-ID reconciliation, not an inference on error
                }
            }
            entries = reconciled
            return entries.sorted { $0.time > $1.time }
        } }
        return .deleted(DeletedResult(entries: entries))
    }
    private func restore(_ reference: String, target: String?) throws -> OperationResult {
        let entries = try io { try journal.read() }
        let candidates = entries.filter { same($0.id, reference) || $0.title == reference }
        let savedID = candidates.isEmpty ? nil : try resolve(reference, candidates.map { ($0.id, $0.title) })
        let entry = entries.first { $0.id == savedID }
        let id = entry?.id ?? reference
        guard let list = target ?? entry?.listID else { throw Failure(.invalidInput, "Restore requires saved original list or explicit target") }
        let listID = try resolveList(list, backend.catalog()).id
        guard try backend.restorableState(id: id) == .restorable else { throw Failure(.notFound, "Reminder is not restorable") }
        let expected = entries.filter { same($0.id, id) || $0.parentID.map { same($0, id) } == true }.map(\.id)
        // A saved child can only rejoin an active top-level parent in the target list.
        // Restoring a whole root+children tree instead validates internal parents after native restore.
        try validateParent(id: id, parentID: entry?.parentID, listID: listID,
                           hasChildren: expected.contains { !same($0, id) })
        let result = try mutate { try backend.restoreReminder(id: id, listID: listID, knownChildIDs: expected.filter { !same($0, id) }) }
        guard case .mutation(var mutation) = result else { return result }
        let ids = Array(Set([id] + expected + mutation.affectedIDs)).sorted()
        mutation.affectedIDs = ids; evidence = mutation
        var restored: [Reminder] = []
        for affectedID in ids {
            // Do not compactMap: a missing child or a failed read invalidates confirmation.
            let item = try byID(affectedID)
            guard same(item.fields.listID, listID) else { throw Failure(.conflict, "Restored reminder is in unexpected list") }
            if let saved = entries.first(where: { same($0.id, affectedID) }) {
                let matches = saved.parentID.map { parent in item.fields.parentID.map { same($0, parent) } == true } ?? (item.fields.parentID == nil)
                guard matches else { throw Failure(.conflict, "Restored reminder has unexpected parent") }
            } else if !same(affectedID, id) {
                guard item.fields.parentID.map({ same($0, id) }) == true else { throw Failure(.conflict, "Restored child lost parent") }
            }
            let hasSavedChildren = entries.contains { saved in
                saved.parentID.map { same($0, item.id) } == true && ids.contains { same($0, saved.id) }
            }
            try validateParent(id: item.id, parentID: item.fields.parentID, listID: item.fields.listID,
                               hasChildren: !item.childIDs.isEmpty || hasSavedChildren)
            restored.append(item)
            mutation.reminders = restored; evidence = mutation
        }
        mutation.reminders = restored; evidence = mutation
        try io { try journal.transaction { current in
            current.removeAll { candidate in
                ids.contains(where: { same($0, candidate.id) }) && entries.contains(candidate)
            }
        } }
        return .mutation(mutation)
    }
    private func list(_ input: ListAction) throws -> OperationResult {
        let catalog = try backend.catalog()
        func fields(_ original: ListFields, currentID: String? = nil) throws -> ListFields {
            var f = original; try Validation.list(f)
            if let group = f.groupID { f.groupID = try resolve(group, catalog.groups.map { ($0.id, $0.name) }) }
            if let position = f.position {
                let neighbor = try resolveList(position.neighborID, catalog)
                guard neighbor.id != currentID, neighbor.fields.groupID == f.groupID else { throw Failure(.invalidInput, "Invalid list order neighbor") }
                f.position = replacing(position, with: neighbor.id)
            }
            return f
        }
        switch input {
        case .create(let f):
            let action = ListAction.create(try fields(f)); return try mutate { try backend.list(action) }
        case .update(let name, let f):
            let id = try resolveList(name, catalog).id
            let action = ListAction.update(id, try fields(f, currentID: id)); return try mutate { try backend.list(action) }
        case .delete(let name, _), .clearCompleted(let name, _):
            let id = try resolveList(name, catalog).id
            var query = ReminderQuery(); query.list = id; query.includeCompleted = true; query.limit = Int.max
            let all = try backend.find(query)
            let isDelete: Bool; if case .delete = input { isDelete = true } else { isDelete = false }
            var selected = all.filter { isDelete || $0.fields.completed }
            // Native parent deletion also deletes children, including incomplete children.
            for item in selected {
                for child in try deletionTree(item).dropFirst() where !selected.contains(where: { same($0.id, child.id) }) {
                    selected.append(child)
                }
            }
            if isDelete { return try deleting(selected) { try backend.list(.delete(id, confirmed: true)) } }
            guard !selected.isEmpty else { return .mutation(MutationResult(affectedIDs: [])) }
            // Delete the exact journaled snapshot, not a second native selection that could grow.
            return try deleting(selected) { try backend.deleteReminders(ids: selected.map(\.id)) }
        }
    }
    private func group(_ input: GroupAction) throws -> OperationResult {
        let catalog = try backend.catalog(); let action: GroupAction
        switch input {
        case .create: action = input
        case .rename(let group, let name): action = .rename(try resolve(group, catalog.groups.map { ($0.id, $0.name) }), name: name)
        case .delete(let group, _):
            let id = try resolve(group, catalog.groups.map { ($0.id, $0.name) })
            guard !catalog.lists.contains(where: { $0.fields.groupID.map { same($0, id) } == true }) else {
                throw Failure(.invalidInput, "Group is not empty")
            }
            action = .delete(id, confirmed: true)
        }
        return try mutate { try backend.group(action) }
    }
    private func section(_ input: SectionAction) throws -> OperationResult {
        let catalog = try backend.catalog(); let action: SectionAction
        func sectionID(_ section: String, _ list: String) throws -> String {
            try resolve(section, catalog.sections.filter { same($0.listID, list) }.map { ($0.id, $0.name) })
        }
        switch input {
        case .create(let list, let name): action = .create(list: try resolveList(list, catalog).id, name: name)
        case .rename(let list, let section, let name):
            let id = try resolveList(list, catalog).id
            action = .rename(list: id, section: try sectionID(section, id), name: name)
        case .move(let list, let section, let position):
            let id = try resolveList(list, catalog).id
            let section = try sectionID(section, id), neighbor = try sectionID(position.neighborID, id)
            guard section != neighbor else { throw Failure(.invalidInput, "Cannot order section against itself") }
            action = .move(list: id, section: section, position: replacing(position, with: neighbor))
        case .delete(let list, let section, _):
            let id = try resolveList(list, catalog).id
            action = .delete(list: id, section: try sectionID(section, id), confirmed: true)
        }
        return try mutate { try backend.section(action) }
    }
    private func smartList(_ input: SmartListAction) throws -> OperationResult {
        let catalog = try backend.catalog(); let action: SmartListAction
        func definition(_ original: SmartList) throws -> SmartList {
            var result = original; try Validation.name(result.name); try Validation.filters(result.filters)
            result.filters = try result.filters.map { filter in
                if case .lists(let lists) = filter { return .lists(try lists.map { try resolveList($0, catalog).id }) }
                return filter
            }
            return result
        }
        switch input {
        case .create(let f): action = .create(try definition(f))
        case .update(let name, let f):
            let id = try resolve(name, catalog.smartLists.map { ($0.id, $0.name) })
            guard !catalog.smartLists.first(where: { $0.id == id })!.filters.contains(where: { if case .unknown = $0 { true } else { false } }) else {
                throw Failure(.unsupported, "Cannot edit a smart list with unknown native filters")
            }
            action = .update(id, try definition(f))
        case .delete(let name, _): action = .delete(try resolve(name, catalog.smartLists.map { ($0.id, $0.name) }), confirmed: true)
        }
        return try mutate { try backend.smartList(action) }
    }
    private func template(_ input: TemplateAction) throws -> OperationResult {
        let catalog = try backend.catalog(); let action: TemplateAction
        switch input {
        case .create(let name, let list, let include): action = .create(name: name, list: try resolveList(list, catalog).id, includeCompleted: include)
        case .use(let template, let name): action = .use(try resolve(template, catalog.templates.map { ($0.id, $0.name) }), newListName: name)
        case .delete(let template, _): action = .delete(try resolve(template, catalog.templates.map { ($0.id, $0.name) }), confirmed: true)
        }
        return try mutate { try backend.template(action) }
    }
    private func replacing(_ position: Position, with id: String) -> Position {
        switch position { case .before: .before(id); case .after: .after(id) }
    }
    private func validateInput(_ command: Command) throws {
        func confirmed(_ yes: Bool) throws { guard yes else { throw Failure(.invalidInput, "Explicit confirmation required") } }
        switch command {
        case .find(let query):
            guard query.limit > 0 else { throw Failure(.invalidInput, "Limit must be positive") }
            try Validation.tags(query.tags)
            if let date = query.dueOnOrAfter { try Validation.date(date) }; if let date = query.dueBefore { try Validation.date(date) }
            if let from = query.dueOnOrAfter, let before = query.dueBefore,
               !Validation.components(from).lexicographicallyPrecedes(Validation.components(before)) {
                throw Failure(.invalidInput, "Empty due-date range")
            }
        case .create(let draft):
            var f = draft.fields; if f.listID.isEmpty { f.listID = "default" }; try Validation.fields(f, images: draft.images)
        case .update(_, let version, _), .complete(_, let version, _), .delete(_, let version):
            guard !version.isEmpty else { throw Failure(.invalidInput, "Version is required") }
        case .list(let action):
            switch action {
            case .create(let f), .update(_, let f): try Validation.list(f)
            case .delete(_, let yes), .clearCompleted(_, let yes): try confirmed(yes)
            }
        case .group(let action):
            switch action { case .create(let name), .rename(_, let name): try Validation.name(name)
            case .delete(_, let yes): try confirmed(yes) }
        case .section(let action):
            switch action { case .create(_, let name), .rename(_, _, let name): try Validation.name(name)
            case .delete(_, _, let yes): try confirmed(yes); case .move: break }
        case .tag(let action):
            switch action { case .rename(_, let name): try Validation.tags([name]); case .delete(_, let yes): try confirmed(yes) }
        case .smartList(let action):
            switch action { case .create(let f), .update(_, let f):
                try Validation.list(ListFields(name: f.name, color: f.color, icon: f.icon)); try Validation.filters(f.filters)
            case .delete(_, let yes): try confirmed(yes) }
        case .template(let action):
            switch action { case .create(let name, _, _): try Validation.name(name)
            case .use(_, let name): if let name { try Validation.name(name) }
            case .delete(_, let yes): try confirmed(yes) }
        default: break
        }
    }
}
