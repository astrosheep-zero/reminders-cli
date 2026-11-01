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

An explicit doctor may use an all-zero valid UUID lookup after observing full access: this opens the bridge and performs a direct ID fetch, returning nil for a successful miss, not an empty account scan. The current signed CLI/MCP release regression passed this probe; offline tests never invoke it. See [coverage](coverage.md) for build-specific evidence.

## Core integration refinement

The original Native integration introduced these accepted Core refinements (retained by the facade/MCP revision):

- `Command.catalog(includeTags: Bool)` and `ReminderBackend.catalog(includeTags: Bool)` explicitly select metadata-only or tag-inclusive projection.
- Container/member resolution requests `false`; explicit catalog forwards its flag. Tag mutation uses native label selection directly, not a catalog scan.
- `false` intentionally omits `Catalog.tags`. It does not assert there are zero tags or fabricate zero counts. CLI list/group/section/smart-list/template projections use false, and tag/full catalog views use true.
- `true` enumerates native hashtag labels, selects their reminder IDs, batches the unique selected objects, and counts completion flags without full model conversion or image-byte reads. Native zero-selection labels remain visible with zero counts. Missing APIs, missing selected reminders or read errors propagate.
- Restore rechecks normalized support before the mutation callback, allowing a target account that lacks Recently Deleted to fail `unsupported` before `mutationStarted`.

`docs/core-api.md` documents the refined interface. The Native fake-bridge tests and Core projection test exercise it directly, not through compatibility shims. Restore receipts also distinguish the restored subtree from its already-active touched parent: only the actual validated top-level target-list parent is allowed as auxiliary evidence, its childIDs must include the root, and it is never compacted out of the deletion journal. Saved parent identity remains authoritative. Before any saved-entry validation or journal compaction, non-root/non-auxiliary receipt IDs must occur in the actual restored root's childIDs and point back to that root. An unrelated record's own pending journal entry never grants subtree membership. Missing actual/known child evidence and unrelated auxiliary IDs fail uncertain with all journal evidence retained.

## Native surface

| Family | Concrete system implementation |
| --- | --- |
| Reminder lookup | `REMReminder.objectIDWithUUID:` and `REMStore.fetchRemindersWithObjectIDs:fetchOptions:error:` with due-date-delta alerts. No account scan to locate an ID. A non-UUID reference returns nil for Core's separate exact-title resolution. |
| Ordinary find | Native criteria search owns matching, ordering, offset and limit. Explicit query completed=true/false supplies isCompleted=true/false and takes precedence over includeCompleted; otherwise includeCompleted=true omits this criterion, false/default adds isCompleted=false. Smart-list mode evaluates the native list separately and rejects completed criteria. |
| Rich reminder read | Read-only creationDate/lastModifiedDate/completionDate from native NSDate values become optional Core Date values outside editable fields; facade output uses ISO-8601 UTC and version hashing excludes them. Civil due/start, recurrence, early alerts, flags/priority/urgent/completed, tags, section/manual neighbor, URL/images, location/vehicle/contact triggers, assignment and children. Ordinary reads and post-save attachment confirmation include native image metadata without opening attachment files; only explicit image reads consume bytes. |
| Create/update/complete | Native save request/change items. Updates translate sparse `Change` values: absent never writes, clear is explicit, and set-to-same preserves user intent. Title-only updates do not rebuild alarms, recurrence, assignment, attachments or ordering. |
| Soft deletion | Every supplied root/child enters **one request and synchronous save**. Core journals the exact IDs first. No purge. |
| Deleted-by-ID/restore | Concealed ID fetch; children whose obsolete listID persists are moved in the recovery save. Saved parent evidence is supplied to native recovery; deleted-state root/child parent pointers may be absent, while contradictory pointers refuse before saving. If recovery leaves an expected root/child parent link missing, all missing links are repaired in one conditional follow-up save. An independently deleted subtask rejoins its validated active top-level parent in the target list. Every restored tree record and relationship is read back strictly; repair failure remains outcome-unknown with retained receipts. |
| Lists/groups | Native create/update/remove, grouping, appearance, pin/grocery/sort and ordering contexts. List position is a **write-only ordering directive**: reads return nil, nil writes mean no ordering request, not 'erase manual ordering'. |
| Sections | Native section creation/rename/removal, explicit ordering, membership storage with a nonnil list UUID for 'no section' (nil group UUID is a known native trap). |
| Tags | Native label invocations enumerate names, select reminder IDs and resolve actual hashtag IDs. Rename/removal edits only those native-selected hashtag objects in one request. The saved receipt ID set must equal the selected reminder ID set; equal counts with different IDs fail unknown with evidence. |
| Custom smart lists | Native CRUD/filterData and minimum version, with system evaluation through `REMRemindersListDataView_CustomSmartListInvocation`. Unknown fields remain opaque JSON bytes on read and refuse edits. Multi-list selections explicitly encode OR union. Missing root operation means the native default AND. |
| Templates | Native template view/create/delete and list instantiation. Template projection retains optional color/icon using the shared list/smart-list color decoder (custom hex and lightBlue normalization included). Request-owned created reminder IDs are included with the list receipt when provided by the system. |

Ordinary by-ID reads fetch the requested object directly. Reading its manual neighbor can inspect its own list ordering and sibling IDs; this is not a whole-account lookup. Per-entry-point caches cover by-ID reads, missing/present sections and an incremental per-list ordering cursor. Caches are discarded when the entry point returns. Criteria search passes pagination to native search; smart-list mode slices returned native IDs before conversion. Title resolution uses `predicateDescriptorForRemindersWithTitleEquals:` and the native predicate fetch, then batches full models. List enumeration uses `REMRemindersDataView.fetchRemindersWithListID:includingSubtasks:includingCompleted:error:` with both flags enabled, followed by one full-options batch per list. This exhaustive path remains separate from paginated search.

Criteria queries use `REMSiriSearchDataView_RemindersByCriteriaInvocation` through `REMStore.resultFromPerformingSwiftInvocation:parametersData:storages:error:`. Text modes map to native exact/prefix/word; list criteria use `includeForSiri`. The returned ID page is hydrated with one `fetchRemindersWithObjectIDs:fetchOptions:error:` call including early alerts. Search result storages alone omitted images, a URL and an early alert in live comparison, so they are not used as full reminder models. Returned identities are checked and conversion preserves native order. Child IDs retain the default native subtask-context read; the separate batch-child API’s completion/concealment semantics have not been established.

The Reminders app imports Spotlight search and uses its own search collector. This establishes a distinct UI path, not that the Siri criteria invocation exactly reproduces the app’s UI search. Native criterion results are authoritative even when they differ from a local predicate over exposed fields.

### Mutation receipts and uncertainty

Search pages, smart-list pages and multi-ID post-save readback all share the same full-options batch hydration, preserving requested order and sharing section/ordering caches within the guarded read. A missing requested ID or failed conversion still fails confirmation; it is never silently omitted. Core’s separate relationship rechecks remain in place.

`REMSaveRequest.trackedReminderChangeItems` is captured immediately before and after the synchronous save. Only UUIDs owned by that request are used for reminder receipts; unrelated concurrent list creations are never attributed via before/after list differences. Create, update, tag replacement and template/list creation use this receipt. A recurring completion additionally requires a newly introduced request-owned completed nonrecurring copy with matching title. IDs already tracked before save, including a touched existing parent/neighbor, cannot satisfy this proof; only IDs introduced to that request during save qualify. Missing copy evidence becomes `outcomeUnknown`, not a fabricated complete receipt. Tracking a change is conservative evidence of participation in this save, not an atomic cross-device causal proof.

Native create/update now share one staging/save/receipt/confirmation lifecycle, and entity creation/update share guarded save edges. The shared edges still call the existing request-owned `commit` inside the same exception fence; they do not bypass Core, the mutation marker, journal or readback. Creation fields are lifted into typed sparse sets through Core's private Codable representation, eliminating a second manually maintained field list; only the facade exposes stable public JSON.

A native validation refusal before save is definite. Once `saveSynchronouslyWithError:` has been entered, exception, false result, NSError, lost readback or relationship/attachment confirmation failure is uncertain. Known affected IDs are retained. Confirmation is **local-system acceptance only**, never proof that another device received an iCloud update. Core's version check remains optimistic read/check/save, not a distributed CAS.

### Preflight and exception containment

`checkSupport` first validates/encodes values and image bytes, then calls a **closed capability-token** metadata checker in `Preflight.m`. Repeated capability branches are now a closed ABI-signature table; callers still cannot supply a selector. `RN_SEND` generates otherwise identical nil-receiver fences while retaining explicit object/scalar/void C function signatures for each send. The checker verifies method existence, argument count, return encoding and every argument encoding for the selected command/fields before Core emits `mutationStarted`. Forwarded setters are checked on their actual storage classes; `respondsToSelector:` by itself is not trusted. Arbitrary class/selector names are never accepted from CLI/Core.

Smart-list value preflight retains `SmartFilters.data(smart)`: although impossible enum cases are removed, the encoder still rejects empty definitions, duplicate native families and unbounded date ranges before any store opens. Its entry calls pure Core `Validation.filters`, so invalid priorities and relative ranges fail `invalidInput`, not late `unsupported`. Removing this preflight would defer those remaining shape errors until after the mutation marker.

Resolved restore targets additionally read `account.capabilities.supportsRecentlyDeletedList`; custom-smart creation reads `supportsCustomSmartLists`. These are authorized, nonprompting preflight reads, not saves. Missing/changed APIs and unsupported account capabilities fail explicitly. Metadata cannot prove dynamically forwarded object behavior, per-account data shape, or eventual native success; the entry-point exception fence remains necessary.

Every bridge entry point, including framework loading/store initialization, is exception-fenced. Native nil/error returns do not become empty collections. A successful missing by-ID lookup uses an explicit NSNull sentinel internally, while nil exclusively denotes a failure plus NSError. Missing optional getters fail unsupported rather than silently producing absent values that a later patch might clear.

### Image ownership and consumption

Frontend supplies bounded bytes and a content type, never a source path. ImageIO checks the declared/detected type, one frame, positive/bounded dimensions and decodability. The worker creates an unpredictable private directory with mode 0700 and exclusively created mode-0600 files; suffixes derive from the validated type, not the untrusted filename. Files survive through native save and strict readback.

Cleanup requires each staged input to have a **distinct newly added attachment ID** on its actual owner. Existing attachment IDs cannot satisfy the requirement, and duplicate inputs require multiple new IDs. Any attachment whose resolved file URL still lies inside the staging directory prevents cleanup. Symlink aliases are resolved. A hard link outside the directory is safe to retain after unlinking the staging name and is not rejected merely for sharing an inode. Confirmation uses metadata only; image bytes are never reopened or hashed after save.

A definite pre-save failure cleans safely. An uncertain save or incomplete metadata consumption leaves the private directory intact (`reminder-images-*` under the worker's temporary directory), without automatic retry or age-based deletion that might race native consumption. These leftovers may need manual cleanup after the outcome is established. Native byte normalization, delayed attachment download, and unreadable attachment content do not block a metadata-confirmed add; they affect only explicit image reads.

The prior signed build's explicit image byte read still failed with `NSCocoaErrorDomain/257`. That is a recorded permission-remediation follow-up, not a repaired feature in this revision. The root permission mechanism is not yet established: do not invent an authorization entry, prescribe Full Disk Access as a verified fix, or turn ordinary operations into permission prompts.

## Capability limitations (explicit, not empty success)

- Arbitrary time windows and overdue-only filters are removed from Core and writable discovery; native named time periods and unmodeled date children remain opaque unknown filters on read.
- LocationFilter exposes only `none`, `gettingInCar`, `gettingOutOfCar`, matching native `noLocation`/vehicle forms. Coordinate-free generic/arriving/leaving cases are removed; coordinate-bearing reminder alarms remain supported.
- Date `any` uses `{"any":""}`. Civil ranges and one-direction hour/day/week/month relative ranges are supported. Nonnegative counts with exactly one positive direction are required; zero, bidirectional, negative and minute ranges fail Core `invalidInput`. Smart-filter priorities accept low/medium/high, not none; unmodeled native priority payloads remain unknown. Dynamic `today` and unknown native nested forms are preserved opaquely, not converted to a fixed date.
- Native multiple recurrence rules, recurrence weeks-of-year/days-of-year/setPositions, multiple URL attachments and multiple location/vehicle triggers cannot be represented losslessly by current Core models; reading such a reminder fails unsupported. Unknown enum values also fail explicitly.
- Non-default sort directions not modeled by Core fail unsupported on read, rather than being rewritten as another sort.
- Reminder `clear(position)` is unsupported; the system has no evidenced 'unordered' state. List position instead has the write-only directive semantics documented above.
- Missing optional selectors, unsupported account recovery or custom-smart capabilities, and private-framework drift can prevent an operation. Non-downloaded/unreadable image content can prevent explicit image reads, not ordinary reminder queries or metadata-confirmed adds. Metadata class presence does not promise account support.
- Templates use the default account's template view, as evidenced by the references; accounts with different capabilities may refuse operations. No account selection/invitation feature is claimed.

## API evidence, provenance and observed environment

Independent implementation, **not copied reference bodies**. The unlicensed `apple-mcp` checkout supplied selector/type/schema facts only; `remctl` supplied additional declarations, audit evidence and smart-filter schema facts. Both remained read-only.

- `apple-mcp` revision `28c77470a90957440f2c3d9b1f8626e4857ac176`: `Sources/ReminderKitShim/RKBridge.m`, `Sources/RemindersComponent/Store/Model.swift`, `Sources/RemindersComponent/SmartFilter.swift`, build-app entitlement/signing declarations.
- `remctl` revision `3a105720a603787ffae9abfa29e45c0c9921494e`: `remctl-private.m`, `remctl_smart_lists.py`, `docs/notes/private-api-audit-2026-08-12.md`. Its SQLite/EventKit fallback architecture is **not** adopted.
- Original metadata-inspection host: macOS **27.2**, build **26B123**, arm64; Apple Swift **6.4** (`swiftlang-6.4.0.34.1`), clang **2100.3.34.1**. Current facade/MCP verification uses installed Swift **6.4.2**; deployment remains macOS 26+ with a Swift 6.2 manifest floor.

Class-only inspection loaded ReminderKit/ReminderKitInternal, enumerated method/property metadata, and allocated **no private store, request, reminder or change-item objects**. A separate earlier closed preflight probe tested its 43 declared feature tokens and succeeded after mapping section rename to forwarded `REMListSectionStorage.setDisplayName:`. These are runtime **metadata** observations, not live-data tests. The temporary raw outputs are under ignored `.build/native-metadata.txt`, `.build/native-tag-metadata.txt`, `.build/preflight-probe.txt`; the production preflight table retains the checked return/argument contracts below.

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

Historical reference evidence maps recurrence daily/weekly/monthly/yearly/hourly to 0...4; early-alert minutes/hours/days/weeks/months to 0...4 with **negative** native counts; priorities none/high/medium/low to 0/1/5/9; location arriving/leaving and vehicle getting-in/out to 1/2; joined shared-list member status to 1. These integer meanings were originally established through metadata/reference evidence and pure fixtures. The subsequent signed-build live matrix exercised the supported field families; this revision rechecks them offline, not through new user-data access. Unknown values are refused before they reach native traps.

Reference packaging uses hardened runtime plus `com.apple.security.personal-information.calendars` and opens ReminderKit directly. Neither reference's inspected bridge requires `_LSSet...` or RemindersKitUserExtras startup SPI. That reference inspection is static evidence only. Separately, previous signed-build data operations were live exercised; neither that historical success nor current offline tests establish TCC attribution, newly prompted permission, cross-device sync, or live correctness of the new facade/MCP binary.

## Production size

Physical lines, including comments and blanks (tests/docs/Core integration excluded):

| File | Lines |
| --- | ---: |
| Native Swift: ImageStaging | 92 |
| Native Swift: NativeReminderBackend | 417 |
| Native Swift: SmartFilters | 129 |
| Native Swift: Translation | 214 |
| **Native Swift subtotal** | **852** |
| ObjC: Preflight.m | 103 |
| ObjC: ReminderKitShim.m | 1,071 |
| ObjC public header | 67 |
| **Native production total** | **2,093** |

This is 35 lines below the historical 2,128-line Native starting worktree and 9 below the 2,102-line start of this contract repair, retaining pre-existing image/recovery repairs. Whole `Sources/` implementation files (Swift/ObjC/C) decrease from 4,897 to 4,895 physical lines; including the unchanged headers, 4,997 to 4,995. The unused duplicate section-list bridge entry is removed; list-scoped CLI/MCP sections still use the typed catalog projection. Typed Core operations remain intact. No minification, source relocation into tests or compatibility shim is used.

## Verification and non-evidence

Earlier search/runtime/journal audit worktree (these counts and results predate the native criteria search change; see [coverage](coverage.md)):

```text
swift build                                      PASS
bash scripts/test.sh                             120 tests PASS
  Runtime 15 / Native 40 / Core 37 / CLI+facade+MCP 28
closed RNPreflight feature table + unknown token  PASS (metadata only, no store)
creation-to-sparse-field translation              PASS
```

Current contract/wiring verification on 2026-11-01: plain `swift test` passes **136 tests** (Runtime 15 / Native 47 / Core 44 / CLI+facade+MCP 30), and `git diff --check` is clean. Added/updated tests exercise default/parent-list creation, completion tri-state precedence, strict supported filters/opaque preservation, shared template colors and timestamp projection/version stability through the real current boundaries. No new compatibility helpers, live scripts, packaged app, setup, TCC or keychain operation were used. Linker warnings report missing optional CLT search directories; all tests still pass.

The historical test wrapper loads the **installed real Swift Testing macro plugin** on this CLT release. It does not replace Testing/XCTest with a fake framework. Plain default `swift test` can fail macro discovery on this toolchain; the Holder amended contract verification to the wrapper. Linker warnings about missing optional CLT Developer framework search directories are environment warnings; builds/tests completed.

Offline tests cover civil dates, recurrence/enum mapping, sparse patches and clearing, unsupported-vs-empty, unknown filter preservation and OR/default-AND semantics, image metadata receipts/permissions/lease ownership, exception fences, lazy construction, denial without store construction, exact request-owned receipts, metadata-only catalog, restored subtask parent and strict missing-child confirmation. ObjC bridge doubles implement the current boundary, never an old Core compatibility API.

### Previous live evidence versus this revision

Signed build `D6E95B9B-AA35-422E-984C-3DF067D04B5E` was live exercised on 2026-10-31 after 98 offline tests: supported command/field/filter families, joined assignment, templates/content, ordinary image metadata/add/remove, soft deletion and root/child/parent/image restore variants. The independently deleted subtask parent repair was live rechecked. Those local ignored receipts are summarized in [coverage](coverage.md), not replaced by current mock evidence.

**Subsequent release verification:** signed build `1B3C0A7C-8009-4199-9CCB-4D36646FF410` passed a focused CLI/MCP live regression for doctor, creation/tagged dates, cross-frontend editing, independent child recovery, recurring completed-copy receipts, image metadata/add/remove and owned-list cleanup. This does not repeat the entire prior field/account matrix. No setup, permission prompt or keychain/TCC/settings change was performed. Explicit image bytes remain failed 257 and cross-device sync remains unverified. Full release evidence is in [coverage](coverage.md).
