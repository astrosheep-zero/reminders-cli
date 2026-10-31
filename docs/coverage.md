# Capability and evidence matrix

This is an implementation/evidence ledger, **not a native certification**. Evidence has two distinct generations:

- **Prior signed CLI build `D6E95B9B-AA35-422E-984C-3DF067D04B5E` (2026-10-31):** 98 offline tests and a broad, explicitly authorized local live matrix covered command families, supported field/filter families, shared assignment, templates/content, ordinary image metadata/add/remove, deletion and restore variants. The independently deleted subtask-parent recovery repair was live rechecked. This is real previous-build evidence, not merely metadata inspection or a fake-backend test.
- **Current facade/MCP revision, signed build `1B3C0A7C-8009-4199-9CCB-4D36646FF410`:** `swift build`, 110 offline tests, official SDK protocol/stdio integration, schema/dispatch and cancellation/queue regression. Release packaging, plist and strict signature checks passed. A scoped native CLI/MCP run verified 36-tool discovery, signed doctor/read probe, tagged-date creation, cross-frontend edits, independent child delete/restore with parent retention, recurring completed-copy receipts, image add/metadata/remove and exact returned-ID list cleanup. No setup, keychain change or new authorization prompt was invoked. This focused regression does not rerun every earlier native capability.

The SIGPIPE fix was then rebuilt and signed as `E53D440A-FE73-46F2-8147-B76DE6B96DC7`; plist/strict signature, packaged CLI help, MCP initialize, broken-stdout survival and EOF exit passed on that final bundle. Native code was unchanged after the focused live run above.

Explicit image **byte read** still fails with `NSCocoaErrorDomain/257`; ordinary reads/add/remove do not depend on it. The authorization mechanism/root cause is not established. Improving permission-denial remediation is recorded follow-up, not repaired here; no Full Disk Access workaround is asserted. Cross-device iCloud delivery remains unverified, and successful local data access is not independent proof of macOS TCC attribution or a newly displayed permission prompt.

## Surface coverage

Every data family below is available through peer CLI/MCP frontends using the same facade schema/dispatch; setup is CLI-only. “Prior live” refers only to the signed build above, not this revision.

| Feature family | Surface and safeguards | Evidence / limits |
|---|---|---|
| Find/show/UUID lookup | Typed text/list/smart-list/section/date/status/tags/member predicates; direct by-ID lookup; exact names and ambiguous-name refusal | Prior live; current parser/Core/facade/protocol fixtures. Smart lists use native evaluation, not ordinary-query approximation. |
| Create/edit/complete/uncomplete | Sparse set/clear/absent, mandatory version for edit/done/delete; recurring completion requires request-owned completed-copy evidence | Prior live; current stale-version, callback ordering, sparse-patch and receipt fixtures. Version is optimistic, not atomic cross-device CAS. |
| Title/notes/URL/flags/priority/urgent | All typed editable fields; urgent requires timed due | Prior live; current translation/schema fixtures. Multiple native URLs refuse rather than lose state. |
| Dates/start/early alerts | Civil date versus local date-time; explicit positive early offsets | Prior live; current civil-date/delta fixtures. No accidental midnight/timezone conversion. |
| Recurrence | Frequency/interval/weekdays/signed ordinals/month days/months/count-or-until | Prior live supported families; current parser/Core/Native fixtures. Unsupported multiple rules/week-year/set-position components refuse. |
| Location/car/contact | Explicit coordinates/radius/address/arrival/departure, car and phone/email inputs | Prior live; current fixtures. No Contacts/Location permission or lookup. Unsupported native shapes refuse. |
| Images | Frontend bytes, worker-owned private staging, distinct new attachment IDs/non-staging URLs before cleanup; metadata-only ordinary reads | Prior live add/remove/metadata and parent-image restore; explicit byte read **failed 257**. Current image fixture/lease/creation-translation coverage; no new live repair claim. |
| Move/order/subtasks | One level, same-list parent/section/neighbor checks; no clone-delete move; no parent move with children | Prior live including independent child restore; current strict relationship/receipt/journal tests. Reminder position clear remains unsupported; list position omission is no ordering request. |
| Shared assignment | Already-joined member ID/name or `me`; member enumeration | Prior live assignment; current resolution/translation fixtures. No invitations/account selection. |
| Lists | Metadata enumeration/default marker, create/full replacement edit/delete/clear-completed; appearance/group/pin/kind/sort/order | Prior live; current full family dispatch/Core fixtures. No system-default setter; unsupported native sort/account shapes refuse. |
| Groups | Enumerate/add/rename/delete, confirmed destructive operations | Prior live; current dispatch/Core tests. Nonempty group deletion refuses. |
| Sections | Optional list-scoped listing, add/rename/move/delete | Prior live; current typed schema/dispatch/Native fixtures. Neighbor must be in the same list. |
| Tags | Counts/enumeration/rename/remove with request-owned affected reminders | Prior live; current catalog/receipt fixtures. Only explicit tag/full-catalog/tag-action paths materialize counts. |
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
| `bash scripts/test.sh` | **110 passed**: Runtime 13, Native 36, Core 33, CLI/facade/MCP 28 |
| Official SDK client/server | Initialize 2025-11-25, version 0.1.1, complete tool list, real facade/Core/Runtime calls, structured + text output, wrong/corrupt/contradictory final results |
| Actual `reminder mcp` stdio executable | Initialize/list/invalid arguments/EOF exit, without Native access |
| Cancellation | Task/SDK notification propagation; pre/post-marker classification; pending cancellation and shutdown do not spawn; active worker reaped; SDK ping remains responsive |
| Shared schemas | All 36 tool descriptors have typed dispatch tests; unknown/null/internal-enum/nested fields and missing replacement fields refuse; stable output/version/opaque read preservation |
| Native deduplication | All closed feature-token ABI metadata checks; creation uses real sparse translator; request-owned tracking/staging/readback fixtures |
| `git diff --check` | Pass at final review |

The genuine Swift Testing wrapper explicitly loads the installed TestingMacros plugin and disables unavailable XCTest discovery on this CLT installation; it is not a behavior workaround or an old-API shim. Compiler/linker warnings about nonexistent optional CLT framework/library search directories remain environmental. Verification uses installed Swift **6.4.2**. Resolved manifests are compatible with the advertised Swift 6.2 floor (Collections **1.6.0**, not 1.7.5), but an actual Swift 6.2 compiler build was not run.

One pre-existing Runtime fixture assertion was racy: its observable side effect was written after corruption had already allowed Runtime to terminate the worker. The deliberately corrupt fixture now records that side effect before exposing malformed stdout, deterministically testing conservative unknown classification without delaying or weakening production Runtime behavior. The full suite passes after this fixture correction.

Independent review found that a closed MCP stdout pipe could terminate the process with SIGPIPE before cleanup. MCP startup now ignores SIGPIPE so the SDK receives EPIPE, and EOF can drain the facade. Two real subprocess regressions verify the shipped executable survives the broken output pipe, and an injected active worker is reaped while a queued call never spawns. The failing behavior was reproduced before the fix.

## Size and simplification

Physical source lines include comments/blanks and Swift/C/Objective-C/public headers, excluding tests, dependency checkouts, Package.swift, docs, scripts, resources and ignored build artifacts. The same measure was used for the **4,819-line starting worktree**, including all 16 pre-existing uncommitted files.

| Production area | Lines |
|---|---:|
| CLI | 368 |
| Shared facade | 555 |
| MCP adapter | 52 |
| Core | 1,207 |
| Runtime + C/header | 664 |
| Native + Objective-C/header | 1,971 |
| **Total** | **4,817** |
| **Net change from starting worktree** | **−2** |

Tests are separate: **2,493 lines**. There is no minification, source moved into tests, or compatibility shim recreating a removed public API. Simplification removes the duplicated CLI command allowlist/dispatch in favor of registry-attached typed closures; centralizes public enum schema/codec/output mapping; shares native create/update staging/receipt confirmation and guarded entity save edges; replaces repeated ABI-check branches with one closed signature table; generates identical typed Objective-C send fences; shares creation/sparse-field translation and Core civil components; removes manual per-field patch decoding and an unused section bridge/placeholder. Core mutation count stays computed and is emitted once by facade presentation.

## Live provenance and remaining work

Previous authorized live receipts remain local/ignored under `dist/live-smoke-*`, `dist/interface-live-*`, `dist/live-gap-matrix-*`, `dist/restore-variants-*`, `dist/image-recovery-*`, `dist/parent-image-restore-*` and `dist/templates-content-*`. They are evidence for their recorded signed build, not public test fixtures; do not publish private reminder payloads. The prior smoke's live path was run; the current offline gate neither invokes it nor reuses live IDs.

Current signed receipts remain local/ignored in `dist/mcp-release-live-b019078e-6016-4134-a4b1-922e32ca9b54/`. The first scoped test selected the first affected reminder rather than the intended newly created child; it exercised parent-tree restore, then failed its child assertion. The test was corrected to select the exact returned title/list identity, and its owned list was cleaned by recorded ID before the passing run. No unrelated user records were selected.

Explicit image-read permission remediation and second-device iCloud observation remain unresolved. Do not run setup, signing/keychain actions, live mutation, broad cleanup or publication as part of ordinary offline verification.
