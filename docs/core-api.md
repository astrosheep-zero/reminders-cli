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
- `.delete(id:version:)`, `.restore(id:list:)`, `.deleted`, `.catalog(includeTags: Bool)`;
- `.list(ListAction)`, `.group(GroupAction)`, `.section(SectionAction)`, `.tag(TagAction)`,
  `.smartList(SmartListAction)`, `.template(TemplateAction)`.

`ExecutionResult` encodes `{status: ok|failed|unknown, result?, error?, warnings: []}`.
`OperationResult` cases are `.reminders([Reminder])`, `.catalog(Catalog)`,
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
`Reminder` adds ID, images (ID/name/type/native size), childIDs, and `version() throws -> String`. Image bytes are not part of ordinary reminder reads or version tokens.
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

`ReminderQuery` exposes text, list, smartList, section, includeCompleted, flagged, urgent, repeating,
hasLocation, assigneeID, tags, dueOnOrAfter, exclusive dueBefore, and limit. Backend owns actual
filtering and native smart-list evaluation; Core resolves query container names. Internal name
resolution/deletion scans request limit=Int.max, and must not be silently truncated by a backend.

`Validation.date`, `.recurrence`, `.fields`, and `.name` are public pure functions, usable by the CLI
without native access. `execute` validates syntax before backend preflight; projected patch validation
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

Names match exactly, case-sensitively; IDs match case-insensitively. Duplicate exact names fail ambiguous.
Backend ID lookup is attempted first without an account scan; a missing UUID is not treated as a title.
Non-UUID input may fall back to a complete exact-title search. List/section/group/member names resolve
from catalog. Create may use the unique default list, or parent's list, if draft listID is empty.
Assignment resolves only catalog members of the target list (`me` means its unique current member).
No invitation or system-default-list setter is implied.

## Containers

`Catalog` contains lists, groups, sections, tags, smartLists, templates. `Command.catalog(includeTags:)`
and `ReminderBackend.catalog(includeTags:)` explicitly select tag-inclusive or metadata-only projection.
All Core name/reference resolution requests `includeTags: false`; tag actions request true. False intentionally
omits tags rather than claiming there are no tags, while true requires accurate counts or an error. This
prevents ordinary title edits from enumerating every reminder/image just to resolve a list/member name.
List metadata includes name,
color/icon/group/pin/kind/sort/position/default flag/members. ListAction creates, **fully replaces**
editable list fields, clears completed, or deletes. Full replacement is intentional; a CLI must require
an explicit full definition rather than fill unspecified fields with defaults. Native list `position` is
an ordering directive, not a readable/clearable snapshot field: Native returns nil on read and nil in a
full replacement means no reordering directive. Other editable list fields remain full replacement.
GroupAction creates,
renames, deletes an empty group. SectionAction creates/renames/moves/deletes (deleting retains reminders).
TagAction renames/merges or removes a tag. SmartListAction creates, fully replaces, deletes;
SmartFilter explicitly models tags/date/time/priority/flag/lists/location and preserves unknown fields
as opaque key/Data on read. Unknown filters are not editable, and a full-replacement edit of a list
which already contains unknown filters is rejected rather than discarding unknown native conditions. TemplateAction saves a list (optional
completed items), instantiates with optional new list name, or deletes. All destructive container
actions require confirmed=true, including clear-completed. Bulk mutation failure is unknown/partial,
not a fabricated zero-write failure.

## ReminderBackend obligations

- `checkSupport(for: Command)` is read-only preflight: reject missing methods, unsupported enum/field/
  filter shapes before any save. It may diagnose permissions but must not request them. Defaults fail
  unsupported, never return empty success. Actual native support is not promised by Core models.
- Read methods: `catalog(includeTags:)`, `find(_:)`, `reminder(id:)`, `image(reminderID:imageID:)`,
  `restorableState(id:)`. Reads/preflight **must not save**. `reminder(id:)` uses native by-ID lookup and
  case-insensitive IDs. If an implementation lacks native lookup it must document its fallback.
- `createReminder(_:)`, `updateReminder(id:patch:)`, `deleteReminders(ids:)`,
  `restoreReminder(id:listID:knownChildIDs:parentID:)`, and typed per-family action methods return MutationResult.
  Core calls onMutation immediately before entering any of them. Native must not perform mutating
  methods from any other path. Sparse update must honor absent versus set/clear, never rewrite untouched
  native recurrence/alarm/order state. References in set fields are normalized to IDs by Core.
- Deleting a parent supplies parent + known children to **one backend request/save**; do not loop saves.
  Core clear-completed selects and journals exact IDs, then uses deleteReminders(ids:) rather than asking
  Native to select again. Empty clear-completed returns count=0 without native mutation.
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

`deleted` reconciles using saved IDs while holding the journal lock. Restorable becomes confirmed;
active+pending remains visible as interrupted intent; active+confirmed or authoritative absent can be
removed. All reads must succeed before any reconciliation is persisted—one backend error cannot purge
anything. No time-based pruning is performed. This means pending records can outlive 31 days until
successful authoritative reconciliation. Scope is toolOnly, never system Recently Deleted.

Restore needs original saved list or an explicit target, resolves that list (no default fallback), and
requires native restorable evidence. Root and all known/discovered restored IDs are strictly read back,
including list and parent linkage. Restoring a saved child requires its actual active parent to exist,
be top-level, and belong to the target list before mutation. No implicit detach/reparent policy is used:
a cross-list target or unavailable/invalid saved parent refuses without calling Native. After native
restore, Core rereads every actual referenced parent and checks existence, top-level status and list
membership again, including parents restored in the same root+children operation. Matching a saved
parent ID string alone is never confirmation. Only verified entries whose saved contents still match
are removed; uncertainty preserves intent. There is no permanent purge operation.

## Verification and limits

Focused tests use only in-memory backends and temporary files; journal concurrency tests launch the
built test runner in independent subprocesses. They never request permission or touch real reminders,
setup, signing identities, TCC, or settings. No fake native success is represented as live verification.

Verification: `bash scripts/test.sh --filter ReminderCoreTests` passes 30 standard Swift Testing tests
in two suites, including four subprocesses preserving all 120 journal updates. The Holder-supplied
wrapper loads the installed TestingMacros plugin and disables unavailable XCTest discovery. Plain
`swift test` initially fails this CLT installation's macro discovery; plain native build-system mode
also lacks framework search paths. No behavior/package workaround is included in Core. Core production
sources currently total 1,207 physical lines; the obsolete placeholder is removed. Current whole-worktree
verification and the separate prior signed-live evidence are recorded in [coverage](coverage.md).
