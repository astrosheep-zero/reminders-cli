# Capability and evidence matrix

This is an implementation/evidence ledger, **not a native certification**. Evidence is build-specific:

- **Prior signed CLI build `D6E95B9B-AA35-422E-984C-3DF067D04B5E` (2026-10-31):** 98 offline tests and a broad, explicitly authorized local live matrix covered command families, supported field/filter families, shared assignment, templates/content, ordinary image metadata/add/remove, deletion and restore variants. The independently deleted subtask-parent recovery repair was live rechecked. This is real previous-build evidence, not merely metadata inspection or a fake-backend test.
- **Published facade/MCP baseline, signed build `1B3C0A7C-8009-4199-9CCB-4D36646FF410`:** `swift build`, 110 offline tests, official SDK protocol/stdio integration, schema/dispatch and cancellation/queue regression. Release packaging, plist and strict signature checks passed. A scoped native CLI/MCP run verified 36-tool discovery, signed doctor/read probe, tagged-date creation, cross-frontend edits, independent child delete/restore with parent retention, recurring completed-copy receipts, image add/metadata/remove and exact returned-ID list cleanup. No setup, keychain change or new authorization prompt was invoked. This focused regression does not rerun every earlier native capability.

The SIGPIPE fix was then rebuilt and signed as `E53D440A-FE73-46F2-8147-B76DE6B96DC7`; plist/strict signature, packaged CLI help, MCP initialize, broken-stdout survival and EOF exit passed on that final bundle. Native code was unchanged after the focused live run above.

Explicit image **byte read** still fails with `NSCocoaErrorDomain/257`; ordinary reads/add/remove do not depend on it. The authorization mechanism/root cause is not established. Improving permission-denial remediation is recorded follow-up, not repaired here; no Full Disk Access workaround is asserted. Cross-device iCloud delivery remains unverified, and successful local data access is not independent proof of macOS TCC attribution or a newly displayed permission prompt.

## Search/runtime/journal audit

The earlier local signed build `00B3232A-62DA-4099-B78E-D1B859AAD5F4` passed **120 offline tests** and read-only live regression on macOS 27.2; that evidence predates the current native criteria search change. Production sources were divided between Native/Objective-C review and independent Core/facade/CLI/MCP and Runtime/C-shim reviews; the Native patch received a separate follow-up review.

- Current find uses native criteria matching and pagination; smart-list mode slices native IDs. Internal operations that need completeness use exhaustive enumeration.
- Runtime immediately cleans up an exited worker’s remaining process group instead of waiting for inherited pipes; already-exited leaders skip the unnecessary 100 ms grace delay. Active-worker cancellation keeps the grace period. Regressions cover TERM-resistant descendants, pipe draining and normal completion.
- Native mutation receipt readback visits all affected IDs in one guarded read, sharing section/ordering caches. Restore membership and unchanged-entry compaction use indexes while preserving first-saved-entry semantics; partial failure still retains verified readback evidence.
- Bulk deletion journal replacement/confirmation uses indexed IDs. Reconciliation performs backend reads outside the journal lock and merges only unchanged snapshot entries. An unexpected whole-list deletion receipt returns unknown with evidence, not false complete success; no cross-device atomic deletion guarantee is introduced.

Evidence remains local under `dist/performance-audit/` and `dist/signing-upgrade-proof/`; no user reminder payloads belong in the public repository. This audit invoked no setup, TCC/keychain changes or real reminder mutations. Initial regression runs exposed an unsupported Swift `fork()` test fixture and a missing fake parent; both fixtures were corrected before the final passing run. The separately tested local same-certificate 0.1.0→0.1.1 replacement retained CLI/MCP access without setup; this does not verify fresh-user Gatekeeper or Homebrew upgrade behavior.

## Native criteria search verification

Local signed build `2F9F9426-8CCE-4C70-A884-E33277DF00E3` passed read-only CLI/MCP checks on the existing 249 reminders. Native page offsets, three text modes, list/status criteria, empty results, obsolete-input rejection and 36-tool MCP discovery were exercised. All 249 full reminder payloads and version tokens matched the prior exhaustive read by ID; six representative records also matched current and prior `show`. This compares field completeness, not old text-matching semantics. No reminders were created or changed.

The final complete-payload run took 0.325 seconds for all 249 reminders versus 1.333 seconds for the prior binary; a three-item page took 0.091 seconds and its MCP call 0.063 seconds. The first single-item call took 0.656 seconds; subsequent text calls took 0.082–0.084 seconds. Three repeat samples during concurrent offline tests ranged 0.131–0.143 seconds for one item and 0.559–0.632 seconds for all items. These are local wall-clock observations, not a latency guarantee.

Full-page comparison caught missing images, URL and early-alert metadata in search-returned storages. The final implementation hydrates the native ID page in one batch with due-date-delta fetch options; no per-result fetch is used for hydration. Default native subtask reads remain because the separate batch-child invocation’s completion/concealment semantics could not be established. A real Objective-C search-entry regression exercises serialization, ordered batch hydration, missing/mismatched IDs and native errors with fake store edges. No live parent/child sample was available in this dataset.

Native `hasDueDate` selected 62 reminders while only 61 exposed a `due` field; direct native invocation confirmed the selection. The wrapper preserves that native result. It does not reconstruct criteria from output fields. The Siri criteria invocation is distinct from the Apple UI Spotlight search path. Local payloads and timing evidence remain ignored under `dist/native-search-research/`.

## Native API expansion verification

Local signed build `1AE75174-733E-499A-81D6-98B1E08D402D` (2026-11-01) passed Release packaging, plist and strict signature checks. The implementation passed **128 offline tests** (Runtime 15, Native 43, Core 42, CLI/facade/MCP 28); after the final facade-description changes, the signed bundle was rebuilt and the read-only live checks plus all 13 Facade/Parser tests passed again. The final independent targeted review reported no remaining concrete blocker. This bundle is local, not installed or published.

Full-model batch hydration now serves search/smart-list pages, mutation/restore receipts and exhaustive list reads. List enumeration uses native `REMRemindersDataView` with subtasks and completed reminders included, rather than EventKit bridging. Title references use the native title-equals predicate directly, without an account scan or local title re-filter. Tags use native label enumeration, reminder-ID selection and hashtag-ID selection; counts batch-read the unique selected reminders, and rename/remove operate on native hashtag identities rather than reproducing label matching in Swift. Tag validation runs before the mutation marker and again during mutation; receipts compare normalized full ID sets, not just counts, and preserve both sets as evidence on mismatch.

On the final signed bundle, all **249 full reminder payloads and version tokens** matched the pre-expansion binary. Five representative title lookups retained rich fields (including early alerts, URL, location and image metadata); tags and one smart list matched, as did MCP tags/title calls. Missing titles returned `notFound`; a missing-tag rename was refused during read-only preflight, before saving. A separately signed direct bridge probe exercised exhaustive native list reads across 11 eligible lists: 249 records, including 241 completed, each matching its full `show` payload. Thirty distinct titles were also checked during native predicate research; sampled case variants did not match, which is not a guarantee about all locales.

The final same-title comparison took **0.168 seconds versus 1.354 seconds** for the pre-expansion binary (about 8× in this sample); tags took 0.120 versus 0.145 seconds. The first full read in that final run took 0.905 versus 0.373 seconds. Earlier alternating full-read repeats were 0.409/0.367/0.364 seconds for the new implementation and 0.366/0.357/0.380 seconds for the old one: broadly comparable, not evidence of a general full-read speedup. These are local wall-clock samples, not performance guarantees.

The live tag sample contains two labels and covers completed reminders; zero-selection labels, native aliases and hidden-item behavior were not live-verified. Offline fixtures cover native selection, zero-selection labels, target-identity deduplication, preflight refusal and receipt-set mismatch. Tag mutations were tested offline only; this expansion made no real reminder changes and invoked no setup or TCC/keychain permission changes. Separate child-ID/batch-child APIs remain unused because completion/concealment behavior lacks a suitable nonempty live sample. Search/SearchFlat organization only reorders supplied IDs and does not establish complete position neighbors, so it does not replace position scans. Native counts were not exposed as a new public command, and incremental change tracking would require a separate long-lived architecture. Local payloads and timing evidence remain ignored under `dist/native-api-expansion-research/`.

## Surface coverage

Every data family below is available through peer CLI/MCP frontends using the same facade schema/dispatch; setup is CLI-only. “Prior live” refers only to the signed build above, not this revision.

| Feature family | Surface and safeguards | Evidence / limits |
|---|---|---|
| Find/show/UUID lookup | Native criteria text/list/status and smart-list modes, pagination; direct by-ID lookup; native title-equals resolution and ambiguous-name refusal | Prior live; current parser/Core/facade/protocol fixtures. Smart lists use native evaluation, not ordinary-query approximation. |
| Create/edit/complete/uncomplete | Sparse set/clear/absent, mandatory version for edit/done/delete; recurring completion requires request-owned completed-copy evidence | Prior live; current stale-version, callback ordering, sparse-patch and receipt fixtures. Version is optimistic, not atomic cross-device CAS. |
| Title/notes/URL/flags/priority/urgent | All typed editable fields; urgent requires timed due | Prior live; current translation/schema fixtures. Multiple native URLs refuse rather than lose state. |
| Dates/start/early alerts | Civil date versus local date-time; explicit positive early offsets | Prior live; current civil-date/delta fixtures. No accidental midnight/timezone conversion. |
| Recurrence | Frequency/interval/weekdays/signed ordinals/month days/months/count-or-until | Prior live supported families; current parser/Core/Native fixtures. Unsupported multiple rules/week-year/set-position components refuse. |
| Location/car/contact | Explicit coordinates/radius/address/arrival/departure, car and phone/email inputs | Prior live; current fixtures. No Contacts/Location permission or lookup. Unsupported native shapes refuse. |
| Images | Frontend bytes, worker-owned private staging, distinct new attachment IDs/non-staging URLs before cleanup; metadata-only ordinary reads | Prior live add/remove/metadata and parent-image restore; explicit byte read **failed 257**. Current image fixture/lease/creation-translation coverage; no new live repair claim. |
| Move/order/subtasks | One level, same-list parent/section/neighbor checks; no clone-delete move; no parent move with children | Prior live including independent child restore; current strict relationship/receipt/journal tests. Reminder position clear remains unsupported; list position omission is no ordering request. |
| Shared assignment | Already-joined member ID/name or `me`; member enumeration | Prior live assignment; current resolution/translation fixtures. No invitations/account selection. |
| Lists | Metadata enumeration/default marker, create/sparse edit/delete/clear-completed; appearance/group/pin/kind/sort/order | Prior live; current full family dispatch/Core fixtures. No system-default setter; unsupported native sort/account shapes refuse. |
| Groups | Enumerate/add/rename/delete, confirmed destructive operations | Prior live; current dispatch/Core tests. Nonempty group deletion refuses. |
| Sections | Optional list-scoped listing, add/sparse edit/delete; name and position share one save | Prior live; current typed schema/dispatch/Native fixtures. Neighbor must be in the same list. |
| Tags | Counts/enumeration/rename/remove with request-owned affected reminders | Prior live; current catalog/receipt fixtures. Tag/full-catalog reads count native-selected IDs; tag mutations select native reminder/hashtag IDs directly and validate receipt membership. |
| Smart lists | Native CRUD/content evaluation; opaque unknown filters preserved on read | Prior live supported filters and explicit unsupported refusals; current schema/Native fixtures. Arbitrary time, overdue-only, coordinate-free place, bidirectional/minute relative ranges, duplicate native filter families/no-priority remain unsupported. Lists with unknown filters are read-only. |
| Templates | Native list/create/include-completed/use/delete, no synthetic cloning | Prior live including instantiated content; current typed dispatch/Native fixtures. Account capabilities may refuse. |
| Soft delete/recovery | Journal intent persisted before save; known root/children and saved parent evidence; strict restore readback/compaction | Prior live root/child/parent/image variants; current isolated-journal fixtures. Scope is `toolOnly`, never all-system Recently Deleted; no purge. |
| Permissions/doctor | Only explicit CLI setup requests access; doctor optionally probes sentinel UUID when already authorized | Prior signed data access and diagnostic evidence; current pure probe gating/denial fixtures. No new prompt or independent TCC-attribution claim. MCP has no setup tool. |
| Isolation/errors/cancellation | Same-executable one-shot worker, disclaimed spawn, buildID, bounded bytes/deadline, marker-aware unknown, terminate/reap, no retry | Prior signed native worker evidence; current real subprocess fixtures plus official SDK cancellation and actual stdio initialize/list/invalid-call/EOF. Queued cancellation cannot spawn later. |
| Packaging | Reminder.app, exec wrapper, explicit signing identity/ad-hoc warning | Current Release build, plist and strict signature verification passed; Homebrew installation verification is recorded separately. |
| iCloud | Local save acceptance only | **Cross-device delivery unverified.** |

A missing selector/account capability is explicit `unsupported`, never fabricated empty success. Pre-save refusal is definite; anything uncertain after the mutation boundary remains outcomeUnknown with underlying code, affected IDs and journal evidence retained. Metadata class presence cannot establish account-specific behavior.

## Current offline verification

| Check | Result |
|---|---|
| `swift build` | Pass; executable/Swift/C/Objective-C modules compile, no distribution signing script |
| `bash scripts/test.sh` | **159 passed**: Runtime 15, Native 58, Core 51, CLI/facade/MCP 35 |
| Official SDK client/server | Initialize 2025-11-25, version 0.2.0, complete tool list, real facade/Core/Runtime calls, structured + text output, wrong/corrupt/contradictory final results |
| Actual `reminder mcp` stdio executable | Initialize/list/invalid arguments/EOF exit, without Native access |
| Cancellation | Task/SDK notification propagation; pre/post-marker classification; pending cancellation and shutdown do not spawn; active worker reaped; SDK ping remains responsive |
| Shared schemas | All 35 tool descriptors have typed dispatch tests; unknown/null/internal-enum/nested fields, conflicting input sources, empty edits and invalid creation fields refuse; stable output/version/opaque read preservation |
| Native deduplication | All closed feature-token ABI metadata checks; creation uses real sparse translator; request-owned tracking/staging/readback fixtures |
| `git diff --check` | Pass at final review |

The genuine Swift Testing wrapper explicitly loads the installed TestingMacros plugin and disables unavailable XCTest discovery on this CLT installation; it is not a behavior workaround or an old-API shim. Compiler/linker warnings about nonexistent optional CLT framework/library search directories remain environmental. Verification uses installed Swift **6.4.2**. Resolved manifests are compatible with the advertised Swift 6.2 floor (Collections **1.6.0**, not 1.7.5), but an actual Swift 6.2 compiler build was not run.

The pre-existing normal-worker-exit timing assertion also failed during interface integration and final v0.2.0 release verification; unchanged full reruns passed. Its time limit was not relaxed. The v0.2.0 simplification preserves the existing tests and removes no safety checks. New sparse smart-list/section and normalized-input evidence is offline; earlier signed live results above do not certify these new mutation paths.

One pre-existing Runtime fixture assertion was racy: its observable side effect was written after corruption had already allowed Runtime to terminate the worker. The deliberately corrupt fixture now records that side effect before exposing malformed stdout, deterministically testing conservative unknown classification without delaying or weakening production Runtime behavior. The full suite passes after this fixture correction.

Independent review found that a closed MCP stdout pipe could terminate the process with SIGPIPE before cleanup. MCP startup now ignores SIGPIPE so the SDK receives EPIPE, and EOF can drain the facade. Two real subprocess regressions verify the shipped executable survives the broken output pipe, and an injected active worker is reaped while a queued call never spawns. The failing behavior was reproduced before the fix.

## Size and simplification

Physical source lines include comments/blanks and Swift/C/Objective-C/public headers, excluding tests, dependency checkouts, Package.swift, docs, scripts, resources and ignored build artifacts. The same measure was used for the **4,819-line starting worktree**, including all 16 pre-existing uncommitted files.

| Production area | Lines |
|---|---:|
| CLI | 369 |
| Shared facade | 578 |
| MCP adapter | 52 |
| Core | 1,331 |
| Runtime + C/header | 674 |
| Native + Objective-C/header | 2,128 |
| **Total** | **5,132** |
| **Net change from original starting worktree** | **+313** |

Tests are separate: **3,641 lines**. The v0.2.0 simplification round reduces production sources from 5,155 to 5,132 (**−23**). Restore uses one ordered per-ID journal snapshot index instead of a custom hash adapter and a second first-entry index; exact-entry equality still protects concurrent deletion intents. Existing optional-ID equality and outer error normalization replace duplicate checks, and partial readback evidence no longer needs a separate boolean. The full existing suite is retained. There is no minification, source moved into tests, or compatibility shim.

The preceding public-interface changes added 129 lines against `e02a973` (5,026). After this round the aggregate is still **+106**, so the aggregate source-reduction requirement remains unresolved; fewer tools are not counted as fewer source lines. Earlier simplification already removed duplicate CLI dispatch, centralized schema/codec mapping, shared native save/readback paths and consolidated closed ABI checks. Those earlier changes are not credited again to this round.

## Live provenance and remaining work

Previous authorized live receipts remain local/ignored under `dist/live-smoke-*`, `dist/interface-live-*`, `dist/live-gap-matrix-*`, `dist/restore-variants-*`, `dist/image-recovery-*`, `dist/parent-image-restore-*` and `dist/templates-content-*`. They are evidence for their recorded signed build, not public test fixtures; do not publish private reminder payloads. The prior smoke's live path was run; the current offline gate neither invokes it nor reuses live IDs.

Current signed receipts remain local/ignored in `dist/mcp-release-live-b019078e-6016-4134-a4b1-922e32ca9b54/`. The first scoped test selected the first affected reminder rather than the intended newly created child; it exercised parent-tree restore, then failed its child assertion. The test was corrected to select the exact returned title/list identity, and its owned list was cleaned by recorded ID before the passing run. No unrelated user records were selected.

Explicit image-read permission remediation and second-device iCloud observation remain unresolved. Do not run setup, signing/keychain actions, live mutation, broad cleanup or publication as part of ordinary offline verification.
