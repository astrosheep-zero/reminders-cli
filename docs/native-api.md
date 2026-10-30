# Native ReminderKit adapter: API, evidence, and limits

## Construction and permission separation

```swift
let backend = NativeReminderBackend() // No framework load, store, prompt, or read.
NativeReminderBackend.authorizationStatus() // String, nonprompt EventKit status only.
NativeReminderBackend.capabilities() // [String], implementation declaration, NOT live verification.
try NativeReminderBackend.requestAuthorization() // Bool; setup ONLY. false means denied.
```

The implementation conforms to `ReminderCore.ReminderBackend`. Calls are synchronous and serialized by an `NSRecursiveLock`; one worker owns one instance. `ReminderKitShim` contains every private class, selector, typed `objc_msgSend` cast, private invocation payload and Objective-C exception boundary. Swift contains value translation, byte validation/staging, and typed backend composition, never a private framework object. Foundation bridge dictionaries are internal to Native, not an external command API. No SQL, AppleScript, EventKit data fallback, invitations, clone/delete moves, GUI, entitlement installation, TCC modification, keychain operation, or automatic write retry is implemented.

Normal reads require already granted full Reminders access before opening the native store. They never request it. Setup alone constructs an `EKEventStore` and requests full access, with a bounded synchronous wait and an Objective-C exception fence. Backend construction, `authorizationStatus`, and static `capabilities` do not construct `REMStore`. The status function returns `unavailable` if the public-framework query throws an Objective-C exception.

An explicit doctor may use an all-zero valid UUID lookup after observing full access: this opens the bridge and performs a direct ID fetch, returning nil for a successful miss, not an empty account scan. This probe was **not executed** during verification.

## Core integration refinement

The Holder authorized these narrow changes to the accepted Core interface in this Native contract:

- `Command.catalog(includeTags: Bool)` and `ReminderBackend.catalog(includeTags: Bool)` explicitly select metadata-only or tag-inclusive projection.
- Every Core name/reference-resolution path requests `false`; explicit catalog forwards its flag; a tag mutation requests `true`.
- `false` intentionally omits `Catalog.tags`. It does not assert there are zero tags or fabricate zero counts. CLI list/group/section/smart-list/template projections use false, and tag/full catalog views use true.
- `true` reads only raw `hashtags`/`isCompleted` rows for accurate tag counts. It never calls full reminder conversion, recurrence parsing, image reading or hashing. A missing tag API/read error propagates.
- Restore rechecks normalized support before the mutation callback, allowing a target account that lacks Recently Deleted to fail `unsupported` before `mutationStarted`.

`docs/core-api.md` documents the refined interface. The Native fake-bridge tests and Core projection test exercise it directly, not through compatibility shims. Restore receipts also distinguish the restored subtree from its already-active touched parent: only the actual validated top-level target-list parent is allowed as auxiliary evidence, its childIDs must include the root, and it is never compacted out of the deletion journal. Saved parent identity remains authoritative. Before any saved-entry validation or journal compaction, non-root/non-auxiliary receipt IDs must occur in the actual restored root's childIDs and point back to that root. An unrelated record's own pending journal entry never grants subtree membership. Missing actual/known child evidence and unrelated auxiliary IDs fail uncertain with all journal evidence retained.

## Native surface

| Family | Concrete system implementation |
| --- | --- |
| Reminder lookup | `REMReminder.objectIDWithUUID:` and `REMStore.fetchRemindersWithObjectIDs:fetchOptions:error:` with due-date-delta alerts. No account scan to locate an ID. A non-UUID reference returns nil for Core's separate exact-title resolution. |
| Ordinary find | Native list/reminder fetches, then explicit typed query predicates. Smart-list filters are **not** simulated by these predicates. |
| Rich reminder read | Civil due/start, recurrence, early alerts, flags/priority/urgent/completed, tags, section/manual neighbor, URL/images, location/vehicle/contact triggers, assignment and children. Full reminder image metadata includes SHA-256 of actual bytes. |
| Create/update/complete | Native save request/change items. Updates translate sparse `Change` values: absent never writes, clear is explicit, and set-to-same preserves user intent. Title-only updates do not rebuild alarms, recurrence, assignment, attachments or ordering. |
| Soft deletion | Every supplied root/child enters **one request and synchronous save**. Core journals the exact IDs first. No purge. |
| Deleted-by-ID/restore | Concealed ID fetch; children whose obsolete listID persists are checked through their parent. Known and native-discovered children are restored/reparented in one save. An independently deleted subtask rejoins its validated active top-level parent in the target list. Every restored tree record and relationship is read back strictly. |
| Lists/groups | Native create/update/remove, grouping, appearance, pin/grocery/sort and ordering contexts. List position is a **write-only ordering directive**: reads return nil, nil writes mean no ordering request, not 'erase manual ordering'. |
| Sections | Native section creation/rename/removal, explicit ordering, membership storage with a nonnil list UUID for 'no section' (nil group UUID is a known native trap). |
| Tags | Requested catalog counts use a lightweight raw scan; rename/removal uses one request. Receipts come from the request's actual selected changes, not an earlier Swift scan or a count-only comparison. |
| Custom smart lists | Native CRUD/filterData and minimum version, with system evaluation through `REMRemindersListDataView_CustomSmartListInvocation`. Unknown fields remain opaque JSON bytes on read and refuse edits. Multi-list selections explicitly encode OR union. Missing root operation means the native default AND. |
| Templates | Native template view/create/delete and list instantiation. Request-owned created reminder IDs are included with the list receipt when provided by the system. |

Ordinary by-ID reads fetch the requested object directly. Reading its manual neighbor can inspect its own list ordering and sibling IDs; this is not a whole-account lookup. Per-entry-point caches avoid repeated sibling fetches while converting a list and are discarded when the entry point returns. Full ordinary find can enumerate selected lists; explicitly requesting full tag counts enumerates raw tag state. Neither behavior is imposed by metadata catalog/reference resolution.

### Mutation receipts and uncertainty

`REMSaveRequest.trackedReminderChangeItems` is captured immediately before and after the synchronous save. Only UUIDs owned by that request are used for reminder receipts; unrelated concurrent list creations are never attributed via before/after list differences. Create, update, tag replacement and template/list creation use this receipt. A recurring completion additionally requires a newly introduced request-owned completed nonrecurring copy with matching title. IDs already tracked before save, including a touched existing parent/neighbor, cannot satisfy this proof; only IDs introduced to that request during save qualify. Missing copy evidence becomes `outcomeUnknown`, not a fabricated complete receipt. Tracking a change is conservative evidence of participation in this save, not an atomic cross-device causal proof.

A native validation refusal before save is definite. Once `saveSynchronouslyWithError:` has been entered, exception, false result, NSError, lost readback or relationship/attachment confirmation failure is uncertain. Known affected IDs are retained. Confirmation is **local-system acceptance only**, never proof that another device received an iCloud update. Core's version check remains optimistic read/check/save, not a distributed CAS.

### Preflight and exception containment

`checkSupport` first validates/encodes values and image bytes, then calls a **closed capability-token** metadata checker in `Preflight.m`. The checker verifies method existence, argument count, return encoding and every argument encoding for the selected command/fields before Core emits `mutationStarted`. Forwarded setters are checked on their actual storage classes; `respondsToSelector:` by itself is not trusted. Arbitrary class/selector names are never accepted from CLI/Core.

Resolved restore targets additionally read `account.capabilities.supportsRecentlyDeletedList`; custom-smart creation reads `supportsCustomSmartLists`. These are authorized, nonprompting preflight reads, not saves. Missing/changed APIs and unsupported account capabilities fail explicitly. Metadata cannot prove dynamically forwarded object behavior, per-account data shape, or eventual native success; the entry-point exception fence remains necessary.

Every bridge entry point, including framework loading/store initialization, is exception-fenced. Native nil/error returns do not become empty collections. A successful missing by-ID lookup uses an explicit NSNull sentinel internally, while nil exclusively denotes a failure plus NSError. Missing optional getters fail unsupported rather than silently producing absent values that a later patch might clear.

### Image ownership and consumption

Frontend supplies bounded bytes and a content type, never a source path. ImageIO checks the declared/detected type, one frame, positive/bounded dimensions and decodability. The worker creates an unpredictable private directory with mode 0700 and exclusively created mode-0600 files; suffixes derive from the validated type, not the untrusted filename. Files survive through native save and strict readback.

Cleanup requires each staged input to have a **distinct newly added attachment ID** on its actual owner with matching bytes. Existing attachment IDs cannot satisfy the requirement, even if their bytes match. Any attachment whose resolved file URL still lies inside the staging directory prevents cleanup. Symlink aliases are resolved. A hard link outside the directory is safe to retain after unlinking the staging name and is not rejected merely for sharing an inode. Duplicate input bytes require multiple new receipts, not one hash-set hit.

A definite pre-save failure cleans safely. An uncertain save or incomplete consumption leaves the private directory intact (`reminder-images-*` under the worker's temporary directory), without automatic retry or age-based deletion that might race native consumption. These leftovers may need manual cleanup after the outcome is established. Native byte normalization/delayed attachment download can prevent confirmation; that is reported uncertain rather than claiming success and deleting early.

## Capability limitations (explicit, not empty success)

- Core can represent arbitrary time windows; the evidenced native schema uses named time periods. Arbitrary time-filter edits are unsupported.
- Coordinate-free generic/arriving/leaving location filters have no lossless evidenced schema. `noLocation` and vehicle filters are supported; coordinate-bearing reminder alarms are supported.
- Date `any` uses `{"any":""}`. Civil ranges and one-direction hour/day/week/month relative ranges are supported. Overdue-only, bidirectional relative ranges and minute relative ranges are unsupported. Dynamic `today` and unknown native nested forms are preserved opaquely, not converted to a fixed date.
- Native multiple recurrence rules, recurrence weeks-of-year/days-of-year/setPositions, multiple URL attachments and multiple location/vehicle triggers cannot be represented losslessly by current Core models; reading such a reminder fails unsupported. Unknown enum values also fail explicitly.
- Non-default sort directions not modeled by Core fail unsupported on read, rather than being rewritten as another sort.
- Reminder `clear(position)` is unsupported; the system has no evidenced 'unordered' state. List position instead has the write-only directive semantics documented above.
- Missing optional selectors, non-downloaded/unreadable image content, unsupported account recovery or custom-smart capabilities, and private-framework drift can prevent an operation. Metadata class presence does not promise account support.
- Templates use the default account's template view, as evidenced by the references; accounts with different capabilities may refuse operations. No account selection/invitation feature is claimed.

## API evidence, provenance and observed environment

Independent implementation, **not copied reference bodies**. The unlicensed `apple-mcp` checkout supplied selector/type/schema facts only; `remctl` supplied additional declarations, audit evidence and smart-filter schema facts. Both remained read-only.

- `apple-mcp` revision `28c77470a90957440f2c3d9b1f8626e4857ac176`: `Sources/ReminderKitShim/RKBridge.m`, `Sources/RemindersComponent/Store/Model.swift`, `Sources/RemindersComponent/SmartFilter.swift`, build-app entitlement/signing declarations.
- `remctl` revision `3a105720a603787ffae9abfa29e45c0c9921494e`: `remctl-private.m`, `remctl_smart_lists.py`, `docs/notes/private-api-audit-2026-08-12.md`. Its SQLite/EventKit fallback architecture is **not** adopted.
- Observed host: macOS **27.2**, build **26B123**, arm64; Apple Swift **6.4** (`swiftlang-6.4.0.34.1`), clang **2100.3.34.1**; deployment target remains macOS 26+.

Class-only inspection loaded ReminderKit/ReminderKitInternal, enumerated method/property metadata, and allocated **no private store, request, reminder or change-item objects**. A separate closed preflight probe tested all 43 declared feature tokens and succeeded after mapping section rename to forwarded `REMListSectionStorage.setDisplayName:`. These are runtime **metadata** observations, not live-data tests. The temporary raw outputs are under ignored `.build/native-metadata.txt`, `.build/native-tag-metadata.txt`, `.build/preflight-probe.txt`; the production preflight table retains the checked return/argument contracts below.

Selected actual host encodings (object `@`, signed integer `q`, unsigned `Q`, BOOL `B`, double `d`, void `v`):

| Receiver / selector | Observed encoding or normalized return/arguments |
| --- | --- |
| REMStore `initUserInteractive:` | `@20@0:8B16` |
| REMStore `fetchRemindersWithObjectIDs:fetchOptions:error:` | `@40@0:8@16@24^@32` |
| REMStore `resultFromPerformingSwiftInvocation:parametersData:storages:error:` | `@48@0:8@16@24@32^@40` |
| REMSaveRequest `initWithStore:` / `updateReminder:` / `updateList:` | `@24@0:8@16` |
| REMSaveRequest `saveSynchronouslyWithError:` | `B24@0:8^@16` |
| REMSaveRequest `trackedReminderChangeItems` | `@16@0:8`; property `T@"NSMutableDictionary",R,N` |
| REMSaveRequest `addReminderWithTitle:toListChangeItem:` | `@32@0:8@16@24` |
| REMSaveRequest `addGroupWithName:toAccountGroupContextChangeItem:` | `@32@0:8@16@24` |
| REMSaveRequest three-argument `...groupObjectID:` variant | `@40@0:8@16@24@32` also present; production uses the simpler two-argument variant |
| REMSaveRequest list/smart-list/template creation (three object arguments) | object return, `@,@,@` arguments; all selected methods checked by preflight |
| REMReminderChangeItem `addRecurrenceRuleWithFrequency:interval:daysOfTheWeek:daysOfTheMonth:monthsOfTheYear:weeksOfTheYear:daysOfTheYear:setPositions:end:` | `@88@0:8q16q24@32@40@48@56@64@72@80` |
| REMReminderChangeItem `addAlarmWithTrigger:` | `@24@0:8@16` |
| REMReminderStorage `setFlagged:` | `v24@0:8q16` |
| REMReminderStorage `setPriority:` | `v24@0:8Q16` |
| REMReminderChangeItem `setCompleted:` | `v20@0:8B16` |
| REMReminderAssignmentContextChangeItem `addAssignmentWithAssignee:originator:status:` | `@40@0:8@16@24q32` |
| Same context `...AssigneeID:originatorID:status:` | `@40@0:8@16@24q32`; production uses actual joined sharee objects |
| REMReminderHashtagContextChangeItem `addHashtagWithType:name:` | `@32@0:8q16@24` |
| REMReminderAttachmentContextChangeItem `setURLAttachmentWithURL:` | `@24@0:8@16` |
| Same context `addImageAttachmentWithURL:width:height:error:` | `@48@0:8@16Q24Q32^@40` |
| REMDueDateDeltaInterval `initWithUnit:count:` | object return, `q,q` arguments |
| Early-alert context `addDueDateDeltaAlertWithDueDateDelta:` | object return, `@` argument |
| REMMembership initializer | object return, `@,@,B,@` arguments |
| REMStructuredLocation coordinate setters | void return, `d` argument |
| REMAlarmLocationTrigger initializer | object return, `@,q` arguments |

The native constructors/add/set-URL operations wrapped by `Required(...)` use **object-returning** contracts; the selected command/field mutation APIs plus common store/view/fetch-option constructors are checked by `Preflight.m`. Ordinary nullable property getters retain their evidenced object-return contracts and fail through the exception fence if forwarding is unavailable. Void setters use void-return casts and are never fed to ARC as object results. Return ABI is not inferred solely from the reference's function-pointer spelling. NSDate/Foundation operations use their normal compiled declarations.

Historical reference evidence maps recurrence daily/weekly/monthly/yearly/hourly to 0...4; early-alert minutes/hours/days/weeks/months to 0...4 with **negative** native counts; priorities none/high/medium/low to 0/1/5/9; location arriving/leaving and vehicle getting-in/out to 1/2; joined shared-list member status to 1. These integer meanings are validated in pure tests, but were not verified against user data on this host. Unknown values are refused before they reach native traps.

Reference packaging uses hardened runtime plus `com.apple.security.personal-information.calendars` and opens ReminderKit directly. Neither reference's inspected bridge requires `_LSSet...` or RemindersKitUserExtras startup SPI. This is static evidence only; no assertion is made that signing identity, TCC attribution, permissions, hardened-runtime native calls or cross-device sync work in the final packaged app.

## Production size

Physical lines, including comments and blanks (tests/docs/Core integration excluded):

| File | Lines |
| --- | ---: |
| Native Swift: ImageStaging | 99 |
| Native Swift: NativeReminderBackend | 422 |
| Native Swift: SmartFilters | 142 |
| Native Swift: Translation | 227 |
| **Native Swift subtotal** | **890** |
| ObjC: Preflight.m | 175 |
| ObjC: ReminderKitShim.m | 955 |
| ObjC public header | 61 |
| **Native production total** | **2,081** |

This is inside the contract's intended 1,800–3,000-line Native budget; the whole-product budget remains a separate integration constraint. No minification or line padding was used.

## Verification and non-evidence

At candidate preparation:

```text
swift build                                      PASS
bash scripts/test.sh --filter 'ReminderNativeTests|NativeBackendTests'   24 tests PASS
bash scripts/test.sh --filter ReminderCoreTests    33 tests PASS
class-only RNPreflight probe                      43 feature tokens PASS
```

The test wrapper loads the **installed real Swift Testing macro plugin** on this CLT release. It does not replace Testing/XCTest with a fake framework. Plain default `swift test` can fail macro discovery on this toolchain; the Holder amended contract verification to the wrapper. Linker warnings about missing optional CLT Developer framework search directories are environment warnings; builds/tests completed.

Offline tests cover civil dates, recurrence/enum mapping, sparse patches and clearing, unsupported-vs-empty, unknown filter preservation and OR/default-AND semantics, image byte hashes/permissions/lease ownership, exception fences, lazy construction, denial without store construction, exact request-owned receipts, metadata-only catalog, restored subtask parent and strict missing-child confirmation. ObjC bridge doubles implement the current boundary, never an old Core compatibility API.

**Not performed:** any real reminder-store read, any save/delete/restore, any permission request, app launch, keychain/TCC/settings change, hardened-runtime data call, account capability read, remote-device observation, or signing-identity acceptance test. Class metadata + compilation + offline doubles do **not** establish full native runtime correctness. A future human-authorized live smoke must use unique owned fixtures, explicit setup, strict receipt/readback and scoped cleanup; remote sync still needs independent human observation.
