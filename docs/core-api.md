# ReminderCore API (delivery candidate)

`Sources/ReminderCore/Models.swift`, `API.swift`, `Operations.swift`, `Validation.swift`, and
`DeletionJournal.swift` are the source authority. Core imports only Foundation, CryptoKit, and
Darwin (journal). No EventKit/ReminderKit objects, selectors, SQL, frontend file paths, or `[String: Any]`
cross the API. Reference checkouts were read for feature/architecture evidence, not copied or linked.

## Entry points and wire model

```swift
let operations = Operations(
    backend: backend,
    journalURL: injectedURL, // default: ~/Library/Application Support/RemindersCLI/deleted.json
    onMutation: { /* emit Runtime mutationStarted; throw to abort before backend entry */ }
)
let response: ExecutionResult = operations.execute(command)
```

`execute` is synchronous and serialized **per Operations instance**. Use one instance/one backend per
worker; do not use the backend concurrently elsewhere. Backend and callback must not re-enter `execute`.
There is no batch command, automatic retry, global transaction, or cross-device CAS. A successful save
means local acceptance, not proof of iCloud delivery.

Core boundary values are `Codable`, `Sendable`, and `Equatable`; enums retain Swift's synthesized
associated-value representation for internal worker transport and typed Swift clients. This is **not**
the CLI/MCP JSON contract. The shared facade owns a single stable schema/codec/dispatch registry:
public enum objects use `kind`/`value`, and public patches use `set` plus an explicit `clear` array,
never raw `Change` wrappers or `_0`. See [facade API](facade-api.md).

Constructors supply defaults for Swift callers. Synthesized struct decoding requires nonoptional keys,
except `ReminderPatch`: decoding defaults are scoped to its CodingKeys, so omitted changes are absent
and omitted image arrays are empty, without a second manual per-field decoder. Present null still
fails. `Change<T>` remains `.absent`, `.set(T)` or `.clear`; `ReminderPatch()` is entirely absent with
empty image additions/removals. Other Core models do not inherit patch-specific decoding defaults.

`Command` covers:

- `.find(ReminderQuery)`, `.show(String)`, `.image(reminderID:imageID:)`;
- `.create(ReminderDraft)`, `.update(id:version:patch:)`, `.complete(id:version:completed:)`;
- `.delete(id:version:)`, `.restore(id:list:)`, `.deleted`, `.catalog(CatalogScope, list: String? = nil)`;
- `.list(ListAction)`, `.group(GroupAction)`, `.section(SectionAction)`, `.tag(TagAction)`,
  `.smartList(SmartListAction)`, `.template(TemplateAction)`.

`ExecutionResult` encodes `{status: ok|failed|unknown, result?, error?, warnings: []}`.
`OperationResult` cases are `.reminders([Reminder])`, `.catalog(Catalog, scope: CatalogScope = .all)`,
`.mutation(MutationResult)`, `.deleted(DeletedResult)`, `.image(ImageInput)`.
`MutationResult` has `affectedIDs`, verified/known `reminders`, `lists`, and computed `count`.
Count always derives from `affectedIDs.count`, including after decoding a receipt. It is no longer
redundantly encoded in the internal Core mutation payload; facade presentation emits computed count
once in public CLI/MCP output.
A mutation receipt must enumerate every known affected ID,
including recurring copies and subtasks. `DeletedResult.scope` is the one-case enum `toolOnly`.

`Failure` contains stable `code`, `message`, optional `underlyingCode`, and `affectedIDs`.
Exit statuses: invalidInput=1; notFound/ambiguous/conflict=2; permission/sandbox=3;
unsupported=4; outcomeUnknown=5; backend/io/internal=6. Read failures preserve typed Failure exactly.
Untyped backend errors become backend failures; journal errors become io failures. After a mutator is
entered, any thrown error is conservatively outcomeUnknown, preserving its original code as
underlyingCode and any known mutation evidence. The response may include a partial mutation result;
it is not an assertion that all affected IDs were fully verified.

## Fields, queries, validation, versions

`ReminderFields` includes title, listID, notes, due, start, recurrence, earlyAlerts, location, contact,
url, priority, flagged, urgent, completed, tags, parentID, sectionID, position, and assigneeID.
`Reminder` adds ID, images (ID/name/type/native size), childIDs, optional read-only `creationDate`, `lastModifiedDate`, `completionDate` (`Date?`, initializer defaults nil), and `version() throws -> String`. Timestamps remain outside editable `ReminderFields`/`ReminderPatch` and are excluded from version hashing; old fixtures without them still decode and preserve their tokens. CLI/MCP emits these instants as ISO-8601 UTC strings. Image bytes are not part of ordinary reminder reads or version tokens.
`ReminderDraft` adds image bytes. `ReminderPatch` exposes every field as Change plus addImages and
removeImageIDs. Clearing title/list is forbidden; boolean/priority/tags/early-alert clears reset to
false/none/empty; optional-field clears remove that field. Completing uses the same sparse backend
update path; Native must implement native recurring-completion behavior, not simulate its successor.

`ReminderDate.date(CalendarDate)` preserves a date-only value. `.localDateTime(CalendarDate,hour:minute:second:)`
preserves civil Gregorian date/time without imposing a timezone or turning an all-day date into
midnight. Native alone translates to its calendar components. Recurrence models hourly/daily/weekly/
monthly/yearly frequency, positive interval, signed weekday ordinals, month days/months, and either
count or until. Early alerts use positive offsets and explicit units. Location supports explicit
coordinates + arriving/leaving, or car entry/exit. Contact alerts take explicit phones/emails; Core
never queries Contacts. ImageInput contains **bytes + basic filename/content type**, never a path.
Native must stage its own private file and safely manage consumption/cleanup.

`ReminderQuery` exposes text, matching (`exact`, `prefix`, `word`), scope (`SearchScope.all/title/location`), optional tags/excludeTags arrays, tagMatch (`MatchMode.all/any`), list, smartList, includeCompleted, completed (`Bool?`), flagged, urgent, repeating, hasLocation, hasDueDate, limit and offset. Matching/scope default to `word`/`all`; blank text and matching/scope without text are invalid. Tags must be nonempty labels without #/whitespace/NUL; omitted/empty arrays add no filtering. Included tags default to all-of; tagMatch requires nonempty included tags. Native include/exclude selection returns early for no IDs; nonempty IDs intersect other native criteria via objectID. Tag-only queries with includeCompleted=true paginate the native IDs before hydration. Default completion filtering remains a native criterion. No local text/tag filtering is used. Optional-date range encodings are not established, so date criterion filters are deliberately not added. Smart-list mode is mutually exclusive with all criteria, while includeCompleted, limit and offset apply to both modes. In ordinary mode, `completed` takes precedence over `includeCompleted`: true/false requests only completed/incomplete; nil plus includeCompleted=true requests all; nil plus false/default requests incomplete. Smart-list mode rejects any nonnil `completed`. Default limit is 100 and offset 0. Native owns matching and ordering; criteria pagination is native and smart-list pagination slices native IDs. Paging is not a stable snapshot across requests. Core resolves list and smart-list names. Title resolution uses complete native `reminders(matchingTitle:)` results without a local title filter. Deletion uses exhaustive `reminders(listID:)` reads, including completed items and children, never paginated find.

`Validation.query`, `.date`, `.recurrence`, `.fields`, `.filters`, and `.name` are public pure functions, usable by the CLI
without native access. `.fields(..., listRequired: false)` validates unresolved creation drafts without inventing a list identity; after Core resolves parent/default/explicit list, normal field validation requires a nonempty listID. `execute` validates syntax before backend preflight; projected patch validation
and relationships need backend snapshots. Invalid calendar days, time components, recurrence counts/
intervals/ordinals, start-after-due, missing due for repeats/early alerts, untimed urgent, invalid
coordinates, empty contacts/tags, invalid image metadata, section/parent/order errors fail explicitly.
Urgent is not silently disabled when due is cleared: clear urgent in the same patch or the request
fails validation. Native compatibility restrictions are separate explicit unsupported failures.

Version is SHA-256 of canonical sorted-key JSON of all exposed mutable state, including early alerts,
image metadata, and child relationships. Set-like tags, children, contact identifiers, recurrence
members, early alerts, and image metadata are sorted; identifier casing is normalized. Position and
other semantically ordered state retain meaning. No Swift Hasher or timestamp-only token.
Update/complete/delete compare the supplied version, then re-read immediately before mutation.
This remains **non-atomic optimistic read/check/save**: another device can race after the final read.
Parent/section/order validation is also a local snapshot, not a distributed lock.

Container/member names match exactly, case-sensitively; IDs match case-insensitively. Duplicate names fail ambiguous.
Backend ID lookup is attempted first without an account scan; a missing UUID is not treated as a title.
Non-UUID input uses the native title-equals predicate; zero/multiple native candidates fail notFound/ambiguous, without locally filtering the candidates. List/section/group/member names resolve
from catalog. Create may use the unique default list, or parent's list, if draft listID is empty.
Assignment resolves only catalog members of the target list (`me` means its unique current member).
No invitation or system-default-list setter is implied.

## Containers

`Catalog` contains lists, groups, sections, tags, smartLists, templates. `CatalogScope` is `.all` (public kind `catalog`), `.lists`, `.groups`, `.sections`, `.tags`, `.smartLists`, `.templates`. `Command.catalog(scope,list:)` returns `.catalog(Catalog,scope:)`; a list filter is valid only for sections. Core resolves that list's exact name/case-insensitive ID before asking for its sections. Colons in names are ordinary characters. Public JSON keeps the existing catalog/family kind and array shapes.

`ReminderBackend.catalog(_ scopes:Set<CatalogScope>,listID:String?)` reads only requested native families; the one-argument convenience forwards nil listID through the protocol requirement. `.all` reads all families, including accurate tag counts. Unrequested arrays are empty **by scope**, not evidence of global absence. Lists do not load sections/groups/smart lists/templates; sections have their own native read. Reminder create/edit resolve only lists and, if needed, sections in the resolved list. Group/smart/template operations request their relevant families; unrelated malformed smart lists/templates cannot break reminder edits. Tag actions select native labels directly and reject missing identities before mutation.

List metadata includes name/color/icon/group/pin/kind/sort/position/default flag/members. ListAction creates, sparsely updates, clears completed, or deletes. `.update(reference,ListPatch,clear:[ListClear]=[])` merges optional patch fields over the current `ReminderList.fields` in Core. Omitted name/color/icon/group/pin/kind/sort are preserved; explicit false is retained. `ListClear` permits only color/icon/groupID, with duplicate or set/clear conflicts rejected by `ListPatch.validate(clear:)`. A patch or nonempty clear is required. Core validates the merged fields and resolves grouping/order references before mutation. Native receives full resolved fields via `createList(_:)`, `updateList(id:fields:)`, or `deleteList(id:)`, never a clear-completed action. This is a local read/merge/save, not an atomic cross-device merge.

Native list `position` is a write-only directive: reads return nil, omitted patch position means no reordering, and an existing snapshot neighbor is never replayed. Clearing position is not supported. GroupAction creates,
renames, deletes an empty group. SectionAction creates/renames/moves/deletes (deleting retains reminders).
TagAction renames/merges or removes a tag. SmartListAction creates, fully replaces, deletes;
SmartFilter explicitly models tags/date/priorities/flagged/lists/location and preserves unknown fields
as opaque key/Data on read. Date cases are none/any, civil `[from,before)` range, and one-direction relative hours/days/weeks/months. Relative counts must be nonnegative with exactly one positive; minutes, zero/bidirectional ranges and priority none fail `invalidInput` before backend preflight. LocationFilter contains only none/gettingInCar/gettingOutOfCar; arbitrary time and overdue-only cases are removed. Native named time periods or unmodeled date/location payloads remain unknown rather than being guessed. Unknown filters are not editable, and a full-replacement edit of a list
which already contains unknown filters is rejected rather than discarding unknown native conditions. TemplateAction saves a list (optional
completed items), instantiates with optional new list name, or deletes. Catalog groups/templates use `NamedEntity(id:name:color:icon:)`, whose optional color/icon default to nil; Native retains template appearance using the shared color projection. All destructive container
actions require confirmed=true, including clear-completed. Bulk mutation failure is unknown/partial,
not a fabricated zero-write failure.

## ReminderBackend obligations

- `checkSupport(for: Command)` is read-only preflight: reject missing methods, unsupported enum/field/
  filter shapes before any save. It may diagnose permissions but must not request them. Defaults fail
  unsupported, never return empty success. Actual native support is not promised by Core models.
- Read methods: `catalog(_:listID:)`, `find(_:)`, `reminders(listID:)`, `reminders(matchingTitle:)`, `reminder(id:)`, `image(reminderID:imageID:)`,
  `restorableState(id:)`. Reads/preflight **must not save**. `reminder(id:)` uses native by-ID lookup and
  case-insensitive IDs. If an implementation lacks native lookup it must document its fallback.
- `createReminder(_:)`, `updateReminder(id:patch:)`, `deleteReminders(ids:)`,
  `restoreReminder(id:listID:knownChildIDs:parentID:)`, `createList(_:)`, `updateList(id:fields:)`, `deleteList(id:)`, and the other typed per-family action methods return MutationResult.
  Core calls onMutation immediately before entering any of them. Native must not perform mutating
  methods from any other path. Sparse update must honor absent versus set/clear, never rewrite untouched
  native recurrence/alarm/order state. References in set fields are normalized to IDs by Core.
- Deleting a parent supplies parent + known children to **one backend request/save**; do not loop saves.
  Core clear-completed selects and journals exact IDs, then uses deleteReminders(ids:) rather than asking
  Native to select again. ListAction.clearCompleted is Core-only; there is no backend list-action dispatch or duplicate Native selection branch. Empty clear-completed returns count=0 without native mutation.
  No clone/delete cross-list fallback. Refuse cross-list parenting, nesting, self-parenting, parent
  moves with children, or invalid neighbor/section. Backend should enforce native limits too.
- `restoreReminder` gets saved child and parent IDs plus root and target list. It must restore/report all known
  children and any additional native-discovered children. Core independently reads back every ID and
  verifies list and saved parent relationships; any missing/failed read is unknown, not compactMap loss.
  A restored subtask may also touch its already-active parent. Only the restored root's actual top-level
  target-list parent may appear as an auxiliary affected ID, and that parent must list the restored root
  in childIDs. A saved journal parent must match; arbitrary auxiliary records fail confirmation. The
  auxiliary parent is never treated as a restored child or removed from the deletion journal.
- `restorableState` returns authoritative active/restorable/absent. Missing selector, authorization,
  account read, or unsupported evidence is a thrown Failure, **not absent**. No SQL enumeration required.

## Deletion journal and recovery

Sibling `deleted.json.lock` flock covers every load/modify/atomic-replace, across cooperating processes.
Created directory mode 0700, files mode 0600; replacement temp files share the destination filesystem.
Writes are fully written, file-synced/F_FULLFSYNC, renamed, then directory-synced. Read rejects malformed,
unreadable, symlink, and non-regular journals; absent means empty. A throwing transaction body leaves
bytes untouched. This is not a claim of isolation against malicious same-user code or filesystem loss.

Before reminder delete, list delete, or clear-completed can soft-delete anything, Core durably records
id/title/listID/parentID/time with pending state for all known records, including children. Any journal
persistence error prevents backend entry. A crash/failure after start leaves pending intent; after a
successful save it becomes confirmed. If journal confirmation fails after save, result is unknown and
native receipt is retained. Entries from a newer process are not overwritten by an older completion.
List-deletion receipts that include reminder IDs outside the journaled snapshot return unknown and
retain pending evidence. Whole-list deletion is still not atomic with another device adding reminders;
an addition after Native’s final enumeration can remain outside the receipt.

`deleted` snapshots the journal under lock, queries saved IDs outside the lock, then briefly locks
to merge only entries whose complete original value is unchanged. Concurrent additions/changes survive.
Restorable becomes confirmed; active+pending remains visible as interrupted intent; active+confirmed
or authoritative absent can be removed. All backend reads must succeed before any reconciliation is
persisted—one backend error cannot purge anything. No time-based pruning is performed. This means pending records can outlive 31 days until
successful authoritative reconciliation. Scope is toolOnly, never system Recently Deleted.

Restore needs original saved list or an explicit target, resolves that list (no default fallback), and
requires native restorable evidence. Root and all known/discovered restored IDs are strictly read back,
including list and parent linkage. Restoring a saved child requires its actual active parent to exist,
be top-level, and belong to the target list before mutation. No implicit detach/reparent policy is used:
a cross-list target or unavailable/invalid saved parent refuses without calling Native. After native
restore, Core rereads every actual referenced parent and checks existence, top-level status and list
membership again, including parents restored in the same root+children operation. Matching a saved
parent ID string alone is never confirmation. Only verified entries whose saved contents still match
are removed; uncertainty preserves intent. Receipt/tree membership and journal compaction use indexes,
while duplicate saved IDs retain first-entry matching semantics. Partial readback evidence is retained
on failure without repeatedly copying the growing result array. There is no permanent purge operation.

## Verification and limits

Focused tests use only in-memory backends and temporary files; journal concurrency tests launch the
built test runner in independent subprocesses. They never request permission or touch real reminders,
setup, signing identities, TCC, or settings. No fake native success is represented as live verification.

Current 2026-11-01 verification: plain `swift test` passes **147 tests**, including all **47 Core tests** in two suites and four subprocesses preserving all 120 journal updates. Added coverage verifies family-only reads, list-name/ID section resolution (including colon-containing names), create/update dependencies, sparse list preservation, explicit false/clears/conflicts, and exact journaled clear-completed IDs. Native/facade tests use current APIs, not compatibility shims. During iteration this CLT also intermittently missed TestingMacros; a direct `swift test --disable-xctest -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib` run passed with the real installed plugin, followed by a successful plain run. No test wrapper, live script, dist executable, setup, TCC or keychain operation was run. Existing optional CLT linker-search warnings remain. Core sources total **1,293** physical lines. Whole Sources implementation files are **4,895 → 4,928 (+33)**, including headers **4,995 → 5,030 (+35)**; the net-reduction aim was not reached, with no source relocation or count-only compression. This is offline evidence only; historical signed-live evidence remains separate in [coverage](coverage.md).
