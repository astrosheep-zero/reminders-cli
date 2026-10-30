# Capability and evidence matrix

This is an implementation/evidence ledger, **not a native certification**. All live native behavior, permission attribution under a signed host, real restore/attachment consumption, and remote iCloud delivery remain unverified. No automated test opens the real store, prompts, or mutates real reminders. `doctor` reports static implementation metadata and bundle/signature checks; only if already authorized does it attempt a direct sentinel UUID read. That probe's result is explicit, not a claim of TCC attribution or full feature support.

## Surface coverage

| Feature family | CLI/Core surface | Native implementation / explicit limits | Evidence |
|---|---|---|---|
| Find, exact show, UUID lookup | `find`, `show`; typed text/list/smart-list/section/date/status/tags/member predicates | Direct reminder UUID lookup; ordinary queries enumerate selected lists then filter; custom smart lists evaluated through native machinery, not approximated as ordinary filters | Parser + real Core fixture path; native source/build tests, live unverified |
| Create/edit/complete/uncomplete | `add/edit/done --undo`; mandatory edit/done version | Sparse native patch; completion can produce recurring copies, returned as affected IDs | Fixture CRUD and stale-version/no-save assertions; live unverified |
| Titles, notes, URL, flags, priority, urgent | `fields-json` / `set-json` / clear | Multiple native URL attachments cannot be represented losslessly; refuse rather than discard | Typed parser/translation coverage; live unverified |
| Dates/start/early alerts | Civil date versus local date-time tags; early-alert arrays | No conversion to accidental midnight; urgent requires timed due | Core validation and Native translation fixtures; live unverified |
| Repeat rules | Frequency/interval/weekdays and signed ordinals/month days/months/count-or-until | Multiple recurrence rules and unsupported week/year/set-position components refuse rather than lose state | Complex parser + Core validation + Native translation; live unverified |
| Location/car/contact alerts | Explicit place coordinates/radius/address/arrival or departure, car cases, phone/email arrays | No Contacts/Location lookups or permissions; unrepresentable native alert state refuses | Parser + Native fixtures; live unverified |
| Images | Frontend `--image/--image-type`, byte payload; `--remove-images`; `image` reads bytes | Worker-owned private staging; native readback/hash must confirm consumption before cleanup; uncertainty retains evidence | Frontend byte-not-path fixture; Native staging/translation fixtures; real attachment lifecycle unverified |
| Move/order/subtasks | listID, sectionID, position, parentID typed fields | No clone-delete move; one level only; self/cross-list parent/invalid neighbor refused; reminder clear-manual-position unsupported. List position is a write-only ordering directive: nil means no ordering request, not erase ordering | Core relationship tests; Native source/build, live unverified |
| Shared assignment | assigneeID/member exact reference or `me`; joined members in list output | Already-joined members only; **no invitations** | Core resolution and Native translation; live unverified |
| Lists | Metadata-only enumerate/create/full-replacement edit/delete/clear-completed; color/icon/group/pin/kind/sort/order | Default-list marker is readable; no command changes system default. Sort directions not representable by Core (e.g. descending variants) refuse rather than normalize. Native capabilities/account constraints may refuse | Full parser family + Core container tests; Native source/build, live unverified |
| Groups | Enumerate/add/rename/delete; explicit `--yes` | Nonempty group deletion refuses | Parser/Core tests; native live unverified |
| Sections | Enumerate optionally by list; add/rename/move/delete | Scoped native section IDs; destructive operation requires --yes | Parser/Core tests; native live unverified |
| Tags | Counts/enumerate/rename/delete; only explicit tags listing/tag actions request catalog tag materialization | Metadata-only catalogs intentionally omit tags, not fabricated global-empty evidence. Native mutation receipts report affected reminders/count; concurrent mismatch is unknown | Parser/Core/Native fixtures; live unverified |
| Smart lists | Enumerate/add/full-replacement edit/delete and native content query | Writable: tags/priorities/flagged/lists/any-date/civil date ranges/one-direction relative date/no-location/car. Arbitrary time-of-day ranges, coordinate-free place filters, overdue-only filters, no-priority filter, bidirectional/minute relative ranges, duplicate native filter families unsupported. Opaque unknown fields preserved on read; lists containing them are read-only, not overwritten by a replacement | All modeled filter kinds parse; Native rejects unproven shapes explicitly; live unverified |
| Templates | Enumerate/create from list/include-completed/use as new list/delete | Only existing native account capability; no synthetic clone implementation | Parser and Native source/build; live unverified |
| Soft delete/recovery | Versioned delete, `deleted`, restore with saved/explicit destination | Journal scope **toolOnly**, not system Recently Deleted. Parent delete/restore includes known children. No permanent purge | Real Core fixture CRUD/delete/restore with isolated on-disk journal; live unverified |
| Permission/setup/doctor | setup alone requests; doctor checks bundle/signature/status and probes sentinel UUID only when already authorized | Full Reminders only; lazy store; no account scan for sentinel read; setup skips data probe; TCC attribution explicitly unverified | Pure inspection/probe-gating fixtures, no live store; OS prompt/attribution unverified |
| Isolation/protocol/errors | Same executable one-shot `--worker`; buildID; bounded bytes/deadlines; stable JSON/error exits | Required disclaimed spawn; no direct-native fallback. Marker-aware malformed result → unknown; no auto retry | Runtime subprocess fixtures + CLI envelope/composition fixtures; signed real native worker behavior unverified |
| Packaging | Release Reminder.app, plist, minimal entitlement, hardened/ad-hoc signature, exec wrapper | No install, cert/keychain/TCC edits or GUI launch. Existing identity optional; ad-hoc TCC unstable | Final build/plutil/codesign checks required at delivery; not proof of native startup compatibility |
| Cross-device iCloud | No misleading delivery guarantee | Local save only; human observation required | **Unverified** |

A missing private selector/account capability is an explicit `unsupported` error, never empty fabricated success. If established during preflight/read it exits 4; if discovered only after the mutation boundary, Core conservatively returns outcomeUnknown (exit 5), preserving the underlying code. Code implemented against private API evidence is not equivalent to empirical live support. Native's own API evidence document records exact selectors/ABI and platform caveats.

## Offline tests and safety

- Genuine Swift Testing tests, loaded by `bash scripts/test.sh`; normal CLT `swift test` discovery is incomplete on this host. No test-only compatibility APIs are resurrected.
- CLI parser tests include typed recurrence/location/contact/early-alert inputs, filters, every container action, confirmations/version requirements, invalid input, and frontend image bytes.
- CLI composition fixture uses the **actual current** `ReminderBackend`/`Operations` API and serialized worker request/results; checks optimistic conflict, write callback ordering, truthful unknown, stable errors/scope, and CRUD/delete/restore with an isolated temporary journal. The real production frontend is also compiled as a subprocess with an injected protocol worker to verify SIGINT/SIGTERM cancellation, exit classification and worker reaping before/after the mutation marker.
- Runtime's real subprocess fixtures cover handshake/bounds/timeout/crash/protocol ambiguity without Native or real reminder data.
- Native fixtures test translation, static preflight, staging and error boundaries, not real store operations.
- `scripts/live-smoke` is deliberately absent from verification. Without explicit opt-in it refuses before live access; with opt-in it only uses UUIDs returned for its own unique new list/reminder and retains receipts. It stops without cleanup on uncertainty. It has **not** been run live.

## Final integration record

All dependencies were accepted independently before integration. Base main revision: `553b44beb7a2dde65a3c31292e7ec874b423f4d5`, containing accepted Runtime `f4d2b66`, Core `859fd4b`, and accepted Native with its Holder-authorized narrow Core catalog/restore refinement. CLI final commit is recorded in the delivery receipt rather than embedding a self-referential commit hash here.

Actual integrated worktree verification:

| Check | Result |
|---|---|
| `bash scripts/test.sh` | **88 passed**: Runtime 13, Native 24, Core 33, CLI 18 |
| `swift run reminder --help` | Pass, no worker/native access |
| `bash scripts/build-app.sh` | Release arm64 app and exec wrapper built; local ad-hoc signing only |
| `plutil -lint dist/Reminder.app/Contents/Info.plist` | Pass |
| `codesign --verify --strict dist/Reminder.app` | Pass |
| Signature/entitlement inspection | `adhoc,runtime`; only `com.apple.security.personal-information.calendars`; no TeamIdentifier |
| Packaged wrapper JSON help | Pass; ordinary executable shell wrapper, not symlink |
| Packaged invalid edit JSON | `invalidInput`, exit 1, before worker/native access |
| Resource plist and shell syntax | Pass |
| Live smoke without opt-in | Refuses before live access |

The installed CLT emits warnings for nonexistent optional Developer framework/library search directories; all gates above completed successfully. Plain `swift test` is not the amended gate on this host; the documented genuine Testing plugin wrapper is. Packaging/signature verification does **not** verify TCC ownership, permission prompting, a signed native worker's data access, or any account capability.

Physical line counts include comments/blanks and count Swift/C/Objective-C/headers, without minification:

| Category | Lines |
|---|---:|
| CLI production Swift | 801 |
| Core production Swift (including untouched one-line placeholder) | 1,225 |
| Runtime Swift + C/header | 664 |
| Native Swift + Objective-C/header | 2,081 |
| **All production sources** | **4,771** |
| CLI tests (including untouched one-line placeholder) | 426 |
| All tests | 1,854 |
| Build/live-smoke/test scripts | 147 |
| Plist/entitlement resources | 24 |

The production total is below the ~6,000-line target. `Package.swift`, Markdown documentation and ignored build artifacts are outside that source count. Test totals are reported separately and are not used to disguise production size.

### Unfinished versus live-unverified

- **Unfinished implementation within the promised CLI surface:** none. All typed commands/field families are wired to accepted Core/Native. Explicit unsupported native representational/capability restrictions remain documented above and in [Native's evidence](native-api.md); they are not called implemented live behavior.
- **Live-unverified:** real permission prompt/TCC attribution, signed worker reads/writes, actual native field/account behavior, attachment consumption, delete/restore, the opt-in smoke script's live path, and cross-device iCloud delivery. No real store read, setup, save, deletion, restore, GUI launch or installation was performed for these gates.
- The only automatic CRUD/delete/restore evidence is the actual Core engine using isolated deterministic fixtures and temporary journals. Metadata-only catalog omission is intentional and never presented as a verified globally empty tag list.
