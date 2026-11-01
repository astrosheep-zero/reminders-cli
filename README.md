# reminder — native Reminders CLI and MCP

A Swift CLI and local MCP server for Apple Reminders. Requires Apple silicon and macOS 26+ with a Swift 6.2+ toolchain. Uses private ReminderKit APIs: buildability is **not** proof that every feature works on your OS/account. See [installation and MCP client setup](docs/install.md), [coverage and unresolved evidence](docs/coverage.md), and [architecture](ARCHITECTURE.md).

## Acknowledgments and license

Thanks to [xiaofeng-han/apple-mcp](https://github.com/xiaofeng-han/apple-mcp) and [viticci/remctl](https://github.com/viticci/remctl) for architectural and private-API research references. Their repositories were inspected read-only as evidence; their implementations are not vendored or copied here. MCP uses the [official Swift SDK](https://github.com/modelcontextprotocol/swift-sdk).

This project's original code is available under the [MIT license](LICENSE). Dependencies retain their own licenses.

## Build and offline verification

```sh
swift test
swift run reminder --help
bash scripts/build-app.sh
plutil -lint dist/Reminder.app/Contents/Info.plist
codesign --verify --strict dist/Reminder.app
./dist/reminder --help
```

Earlier implementation verification of the preceding search-scope revision with plain `swift test` passed all **147 offline tests** (Runtime 15 / Native 54 / Core 47 / CLI+facade+MCP 31), including scoped catalogs, sparse list edits, native tag selection, text matching and search-scope rejection. The subsequent independent review rerun of plain `swift test` failed compiling `ReminderRuntimeTests` at `@Suite`/`@Test`: the external `TestingMacros` implementation/plugin was not found. The final rerun with the documented explicit real-plugin command passed all **147 tests** with the same breakdown; plain `swift test` is not reliably reproducible on this CLT installation (see the verification command in [native API](docs/native-api.md#verification-and-non-evidence)). `scripts/test.sh` remains the toolchain-discovery wrapper for older CLT setups that need XCTest disabled and the installed TestingMacros plugin explicitly loaded; it does not change product behavior. Tests use fixtures, never request authorization and never open a real Reminders store. Swift dependencies are pinned in `Package.resolved`; MCP uses official Swift SDK 0.12.1.

The build script creates a Release `dist/Reminder.app` and a real **exec wrapper** `dist/reminder` (not a symlink). It only signs local distribution output. Default ad-hoc signing warns because its identity is unstable across rebuilds and may invalidate TCC consent. To use an **existing** signing identity: `SIGNING_IDENTITY='your existing identity' bash scripts/build-app.sh`. For a persistent local default, place its exact 40-hex SHA-1 certificate fingerprint in `~/.config/reminders-cli/signing-identity`; an explicit `SIGNING_IDENTITY` overrides it. An invalid configured fingerprint or unavailable identity fails the build rather than silently falling back to ad-hoc signing. A stable signer and designated requirement can retain TCC consent across updates, but this must be verified on the host; the certificate name alone is not an identity. The script never installs certificates, modifies keychains/TCC, installs into Applications/PATH, launches an app, or runs setup. Hardened-runtime signing and static symbol/ABI checks do not establish live private-API compatibility. Read-only reference inspection found direct ReminderKit bundle/REMStore startup and a hardened-runtime, calendars-only signing example, but no evidence that an extra LaunchServices/UserExtras startup SPI is required. That absence is not a live compatibility guarantee.

For Homebrew installation and source-build invocation, see [the installation guide](docs/install.md). Keep the executable inside its bundle. Prefer the packaged wrapper for permission identity; `swift run` is a development build with a deterministic development handshake ID, not a stable signing identity.

## Permissions

```sh
./dist/reminder doctor --json  # bundle/signature/status; read-only sentinel probe only if already authorized
./dist/reminder setup         # explicit permission request; may show the OS Reminders prompt
```

Only full Reminders access is requested. No Full Disk Access, Automation, Accessibility, Contacts or Location permission is used. Coordinates/phone/email are explicit inputs, not fetched from system stores. Normal operations never prompt; if access is missing they refuse. Explicit `doctor` inspects bundle metadata and the static signature without requesting permission; only when full access is **already** granted does it open a Native store for one direct all-zero UUID sentinel read (expected miss, no account enumeration). Doctor's successful envelope means a diagnostic report was produced, not that access/signing/probe checks all passed. Its `readProbe` reports passed/failed/skipped, and `tccOwnership` remains unverified: neither static authorization nor one successful read independently establishes OS attribution. Setup skips the data probe. Setup has a 120-second worker deadline; other commands have 30 seconds. This repository's unattended verification does **not** run either live command above.

## MCP

Run `reminder mcp` through a stdio MCP client. The official Swift SDK exposes 36 tools with the same schema, validation, worker isolation and output envelopes as the CLI. Permission setup remains an explicit CLI command. See the [complete facade/MCP contract](docs/facade-api.md) and [client configuration](docs/install.md#mcp-client-configuration).

## Commands

`reminder --help` is generated from the same allowlist used by the parser. Every command accepts `--json`. Options take a separate argument, not `--flag=value`; booleans inside JSON are real `true`/`false`. Unknown options, unknown JSON fields, missing positional values, missing version/confirmation, and invalid enum values refuse. Put `--` before dash-prefixed positional text. JSON is inline, shell-quoted, never an arbitrary selector/native RPC escape hatch.

```sh
reminder find --text 'rent' --list 'Home' --limit 20 --json
reminder show REMINDER_UUID --json
reminder add 'Buy fish'                                 # unique default list
reminder add 'Buy milk' --list LIST_UUID --fields-json '{"priority":"high","tags":["shopping"],"flagged":true}'
reminder edit REMINDER_UUID --version VERSION --set-json '{"notes":"oat milk","flagged":false}' --clear due,location
reminder done REMINDER_UUID --version VERSION           # --undo marks incomplete
reminder delete REMINDER_UUID --version VERSION         # includes known children in one save
reminder deleted --json                                 # this tool only, not all-system Recently Deleted
reminder restore REMINDER_UUID                          # journal remembers original list
reminder restore REMINDER_UUID --list LIST_UUID         # explicit destination if journal unavailable
reminder image REMINDER_UUID IMAGE_UUID --json          # bytes as base64, not original file path
```

IDs match case-insensitively; container/member names match exactly. Reminder title references use the native title-equals predicate, and tag names use native label matching. Ambiguous reminder/container names refuse. Versioned reminder output includes `id`, `fields`, `images`, `childIDs`, and `version`, plus optional read-only `creationDate`, `lastModifiedDate`, and `completionDate` as ISO-8601 UTC strings outside `fields`. These timestamps do not change version tokens. Use the token from the most recent `show`/`find` or mutation result. An edit's missing fields stay unchanged; `--set-json` explicitly sets values (including empty string, empty arrays and false); `--clear field,field` explicitly clears. Do not use null as a substitute for clear. Clearing title/list is invalid. List edits are **sparse merges**: omitted name/color/icon/group/pin/kind/sort stay unchanged. Clear optional appearance/grouping only with `--clear color,icon,groupID`; null, duplicate clears, conflicting fields/clear and empty edits refuse. List `position` is a write-only ordering directive: omission means no reordering, never replay an old neighbor. Smart-list edits still require a full replacement:

```sh
reminder lists --json                         # lists, default marker and joined shared-list members
reminder lists add 'Work' --fields-json '{"color":"blue","icon":"briefcase","pinned":true,"kind":"standard","sort":"manual"}'
reminder lists edit LIST_UUID --fields-json '{"name":"New work"}'  # retains color/icon/group/pin/kind/sort
reminder lists edit LIST_UUID --fields-json '{"pinned":false,"sort":"due"}' --clear color,icon
reminder lists edit LIST_UUID --clear groupID                   # explicit ungroup
reminder lists clear-completed LIST_UUID --yes
reminder lists delete LIST_UUID --yes
reminder groups add 'Projects'
reminder groups rename GROUP_UUID --name 'Active projects'
reminder groups delete GROUP_UUID --yes       # nonempty groups refuse
reminder sections --list LIST_UUID
reminder sections add 'Next' --list LIST_UUID
reminder sections edit SECTION_UUID --list LIST_UUID --set-json '{"name":"Later"}'
reminder sections edit SECTION_UUID --list LIST_UUID --set-json '{"name":"Later","position":{"kind":"after","value":"OTHER_SECTION_UUID"}}'
reminder sections delete SECTION_UUID --list LIST_UUID --yes
reminder tags
reminder tags rename old --name new
reminder tags delete old --yes
reminder smart-lists
reminder smart-lists add 'Flagged' --definition-json '{"match":"all","filters":[{"kind":"flagged","value":true}]}'
reminder smart-lists edit SMART_UUID --definition-json '{"id":"SMART_UUID","name":"Flagged","match":"all","filters":[{"kind":"flagged","value":true}]}'
reminder smart-lists delete SMART_UUID --yes
reminder templates
reminder templates add 'Weekly chores' --list LIST_UUID --include-completed
reminder templates use TEMPLATE_UUID --name 'This week'
reminder templates delete TEMPLATE_UUID --yes
```

`sections edit` requires `--list` and a nonempty `--set-json` object with `name`, `position`, or both. Omitted attributes stay unchanged; neither field supports clear/null. Target and before/after neighbor resolve within that list; self, unknown or ambiguous neighbors refuse before mutation. Combined rename/reorder uses one native update/save, not two commands. There are no section rename/move aliases.

Bare `lists/groups/sections/tags/smart-lists/templates` fetch **only their requested native family**, not a full catalog followed by frontend filtering. `lists` does not fetch groups, sections, smart lists or templates. `sections --list` resolves the unique list in Core and fetches only that list's sections (names containing `:` work normally). Reminder create/edit resolve only lists and, when needed, that list's sections. Unrelated malformed smart lists/templates cannot break those commands. Only `tags` and full `catalog --json` request native tag labels and accurate open/total counts. Tag mutations use native label selection directly. `lists clear-completed` selects/journals once in Core, then deletes exactly those IDs, including selected parents' children, in one backend request. There is no invitation command, permanent purge, broad cleanup command, batch command or generic native invocation. Catalog enumeration may fail if an underlying private capability is unavailable; it must not fabricate an empty catalog.

## Exact typed JSON

Create requires only the positional title; `--list` is optional. `--fields-json` overlays Core defaults but cannot change that title or conflict with an explicitly supplied `--list`. With no top-level list, `fields.listID` may supply it; if still empty, Core inherits the parent's list when `parentID` is set, otherwise requires one unique default list. Edit's `--set-json` uses the **same field names and value shapes**, without Change wrappers. Omit optional nil values on creation/replacement; do not supply null. The parser translates edit values to Core's explicit set/clear/absent representation. List creation also overlays defaults. List edit accepts any subset of `fields` plus optional `--clear color,icon,groupID`, with at least one change; omitted fields preserve current values, including false/enum settings. Core resolves grouping/order references and validates the merged fields before mutation. List merging is a local read/merge/save, not an atomic cross-device update. Smart-list creation defaults to an empty id, positional name, `match=all`, empty filters; full replacement requires `id`, `name`, `match`, `filters`.

| Reminder field | JSON value |
|---|---|
| `title`, `listID` | strings; creation title must match the positional title; creation `listID` may supply an omitted `--list` |
| `notes`, `url`, `parentID`, `sectionID`, `assigneeID` | strings; assignment accepts a joined member ID/name or `me` |
| `priority` | `"none"`, `"low"`, `"medium"`, `"high"` |
| `flagged`, `urgent`, `completed` | boolean; urgent requires a timed due date |
| `tags` | string array, no `#` or whitespace in a tag |
| `due`, `start` | tagged civil date/local date-time, examples below; never ISO instants/implicit timezone conversion |
| `recurrence` | frequency, positive interval, weekdays, monthDays, months, optional end |
| `earlyAlerts` | array of `{ "before": positiveInteger, "unit": "minutes|hours|days|weeks|months" }` |
| `location` | tagged place/car trigger, below |
| `contact` | `{ "phones": ["+123456"], "emails": ["someone@example.com"] }` |
| `position` | `{ "kind": "before", "value": "NEIGHBOR_ID" }` or `kind: "after" |

Public enum values use an explicit `kind` discriminator and named payload fields. CLI and MCP share these shapes; Swift's synthesized enum encoding is internal. Dates preserve civil components:

```json
{"due":{"kind":"date","value":{"year":2030,"month":2,"day":3}}}
{"due":{"kind":"localDateTime","value":{"year":2030,"month":2,"day":3},"hour":9,"minute":30,"second":0}}
```

Repeat requires a due date. Frequencies: `hourly/daily/weekly/monthly/yearly`. Weekday numbers run Sunday=1 through Saturday=7; omit `ordinal` for every occurrence, use signed nonzero ordinals for monthly/yearly rules. Month days may be negative (count backwards), never zero. Omit end for indefinite repetition; end is either `{"kind":"count","value":5}` or `{"kind":"until","value":{"year":2031,"month":1,"day":1}}`.

```sh
reminder add 'Monthly check' --list LIST_UUID --fields-json '{"due":{"kind":"date","value":{"year":2030,"month":2,"day":4}},"recurrence":{"frequency":"monthly","interval":1,"weekdays":[{"day":2,"ordinal":1}],"monthDays":[],"months":[],"end":{"kind":"count","value":5}},"earlyAlerts":[{"before":1,"unit":"days"}]}'
reminder edit ID --version VERSION --set-json '{"location":{"kind":"place","title":"Station","latitude":31.2,"longitude":121.5,"radius":100,"address":"explicit address","when":"arriving"}}'
reminder edit ID --version VERSION --set-json '{"location":{"kind":"gettingInCar"}}'
```

Place trigger `when` is `arriving/leaving`; car cases are `gettingInCar/gettingOutOfCar`. Ordinary `find/show` output and post-save attachment confirmation use native image metadata only; attachment bytes are read only by the explicit `image` command. Image attachment: `--image /path/photo.png --image-type image/png` on add/edit; reads bytes **in the frontend** and sends only filename/content-type/bytes. One image per invocation; repeat edits to add more. Remove image IDs using `--remove-images ID,ID`. The serialized entire request/result limit is 16 MiB (base64/JSON overhead means the usable image size is smaller). Filesystem/TCC access can still block frontend file reads. Workers stage their own private files; do not promise attachment consumption from a frontend path.

`find --query-json` accepts `text`, `matching` (`exact`, `prefix`, `word`), `tags`, `excludeTags`, `tagMatch` (`all`, `any`), `list`, `smartList`, `includeCompleted`, `completed`, `flagged`, `urgent`, `repeating`, `hasLocation`, `hasDueDate`, `limit`, and `offset`. Text must contain non-whitespace; matching requires text and defaults to `word`. Text search uses native `textualField` criteria. Tags are arrays of labels without `#`, whitespace or NUL. Included tags default to all-of; `tagMatch:any` selects any included tag. `excludeTags` removes reminders carrying excluded tags; `tagMatch` requires a nonempty included-tags array. Omitted/empty tag arrays add no filtering. For ordinary queries, explicit `completed:true/false` selects only completed/incomplete reminders and overrides `includeCompleted`; without it, `includeCompleted:true` selects both, otherwise only incomplete. For example, `reminder find --query-json '{"completed":true}' --json` requests only completed reminders. Limit defaults to 100 and offset to 0. Smart-list mode accepts `includeCompleted`, limit and offset, but rejects `completed` and other criteria. The CLI accepts kebab-case flags for every field; `--tags-json` and `--exclude-tags-json` take JSON arrays, `--include-completed` is a switch, and the other boolean filters take literal `true` or `false`. `--query-json` expands to the same fields; supplying any field both there and as a flag is invalid, regardless of order. Criteria matching and order are native; criteria pagination uses native offset and limit. Smart-list pagination slices the native ID result in its returned order. Results can change between requests, so paging is not a stable snapshot.

Tag queries use the native include/exclude hashtag invocation. Empty native selection returns immediately; with other criteria, its IDs become an `objectID` criterion for native intersection and pagination. Tags alone with `includeCompleted:true` page the returned IDs before batch hydration. Default incomplete-only behavior and explicit `completed` still use native criteria, never local filtering. For example:

```sh
reminder find --query-json '{"text":"fish","tags":["shopping","home"],"excludeTags":["blocked"],"tagMatch":"any"}' --json
reminder find --query-json '{"tags":["work"],"includeCompleted":true,"limit":20,"offset":0}' --json
```

Search migration: search `scope` is not exposed; CLI/MCP reject it. `tags` is available again as a native ordinary-query filter. `section`, `assigneeID`, `dueOnOrAfter`, `dueBefore`, and creation/modified/completion date ranges remain unsupported; CLI/MCP reject them. Date criterion symbols exist, but their optional-date binary-plist encoding is not established, so this offline-only revision does not guess it. Text matching follows Apple’s native criteria semantics instead of local title/notes substring checks. Use a supported native smart list for its filter families. These changes affect search inputs; reminder editing fields remain available. The implementation uses the native Siri criteria data view, not the Reminders app’s Spotlight search UI.

List fields: `name`, optional `color/icon/groupID/position`, `pinned`, `kind` (`standard/groceries`), `sort` (`manual/due/creation/priority/title`). Colors: `red/orange/yellow/green/light-blue/blue/indigo/pink/purple/brown/gray/rose` or `#RRGGBB`. `position` uses before/after list IDs; `groupID` groups lists. All normal enum restrictions still apply on native support checks.

Smart-list fields: `id`, `name`, optional `color/icon`, `match` (`all/any`), `filters`. Each filter is one tagged value; date entries below are alternatives, since each family may occur only once in a definition:

```json
[
  {"kind":"tags","value":["work","urgent"],"match":"any"},
  {"kind":"date","value":{"kind":"range","from":{"year":2030,"month":1,"day":1},"before":{"year":2030,"month":2,"day":1}}},
  {"kind":"date","value":{"kind":"relative","past":0,"future":7,"unit":"days"}},
  {"kind":"priorities","value":["high","medium"]},
  {"kind":"flagged","value":true},
  {"kind":"lists","value":["LIST_UUID"]},
  {"kind":"location","value":"gettingInCar"}
]
```

Date filters support `none/any`, civil `[from,before)` ranges, and nonnegative relative counts with exactly one of past/future positive, using `hours/days/weeks/months`. Location filters are only `none/gettingInCar/gettingOutOfCar`; smart-filter priorities are only `low/medium/high`. Arbitrary time windows, overdue-only and coordinate-free place variants are not writable API cases; minute, zero or bidirectional relative ranges and priority `none` fail `invalidInput`. Unknown native filter payloads are preserved on **read** as `unknown` with key/base64 bytes, but cannot be submitted as writable filters. A smart list already containing unknown filters is read-only: even omitting those filters from a replacement must refuse rather than silently discard native conditions. For fully modeled lists, roundtrip the complete definition from `result.smartLists` into edit. Roundtrip reminders by copying `fields` into `--set-json` only for fields you intend to change; do **not** blindly replace every native field or pass the whole output envelope.

## Stable output and failure semantics

`--json` writes one envelope to stdout, including parser failures and help. Diagnostics use stderr. Optional result/error members are omitted when absent; warnings is always an array:

```json
{"status":"ok","result":{"kind":"reminders","reminders":[{"id":"…","fields":{"title":"…","listID":"…"},"images":[],"childIDs":[],"version":"…"}]},"warnings":[]}
{"status":"failed","error":{"code":"conflict","message":"…","affectedIDs":[]},"warnings":[]}
{"status":"unknown","error":{"code":"outcomeUnknown","message":"…","affectedIDs":[]},"warnings":["Do not blindly retry writes."]}
{"status":"ok","result":{"kind":"deleted","scope":"toolOnly","entries":[]},"warnings":[]}
```

Template entries expose `id`, `name`, and optional read-only `color`/`icon`; appearance uses the same color normalization as lists and smart lists.

Other result kinds: `mutation` (affectedIDs, count, versioned reminders, lists), `lists/groups/sections/tags/smartLists/templates`, `catalog`, `image` (base64 bytes), `diagnostics`, `help`. Human mode prints concise reminder/list rows, mutation counts and affected IDs, or diagnostic check lines; use `--json` for every field. Reminder rows include version tokens. Errors use stable codes, never localized-string matching:

| Exit | Codes |
|---|---|
| 0 | success |
| 1 | invalidInput |
| 2 | notFound, ambiguous, conflict |
| 3 | permission, sandbox |
| 4 | unsupported |
| 5 | outcomeUnknown |
| 6 | backend, io, internal |

A version check is optimistic **read/check/save**, not atomic cross-device compare-and-swap. Another process/device may race it. No automatic retries. If a worker times out/dies after mutationStarted, final output is missing/malformed after a possible save, or a multi-step write cannot be confirmed, exit 5 means the operation **may have happened**. Inspect returned IDs and state first, never blindly retry creation/deletion. SIGINT/SIGTERM are handled through Dispatch signal sources and RuntimeCancellation so the frontend waits for worker termination/reaping; interruption after mutation may still return unknown. A clean valid final frame is authoritative even if the worker exits abnormally; extra/contradictory stdout invalidates the protocol. Local acceptance is **not** proof of iCloud delivery.

Deletion history lives in `~/Library/Application Support/RemindersCLI/deleted.json` with restrictive permissions, a sibling cross-process lock and atomic replacement. Intent is persisted **before** native deletion; pending evidence survives interruption. `deleted` reconciles saved IDs, never claims all-system Recently Deleted and never infers absence from an error. Restore requires the saved original destination or explicit `--list`. Parent restore includes known children. There is no permanent purge.

## Optional isolated live smoke — NOT run by verification

Only after a human separately permits live testing and explicitly runs setup if needed:

```sh
REMINDER_LIVE_SMOKE=I_UNDERSTAND_THIS_WRITES_TEST_DATA bash scripts/live-smoke
```

Requires Python 3 and the built wrapper. It never calls setup. It creates a uniquely named `RemindersCLI-POC-<UUID>` list, uses **returned UUIDs only**, checks show/edit/complete/delete/restore, then deletes only its own reminder/list. Every command/response is retained under `dist/live-smoke-<UUID>/`; any failure/unsupported/unknown stops without automatic cleanup. Never clean by name or broadly sweep lists/reminders. Recovery evidence/Recently Deleted fixtures may remain; the script cannot permanently purge them. Default tests do not run this script. Cross-device iCloud observation remains manual and unverified.

## Architecture and size

CLI and MCP are peer frontends over a shared Swift facade. Runtime carries bounded opaque bytes through a same-executable disclaimed one-shot worker; Core owns typed validation/resolution/concurrency/journal semantics; Native alone translates ReminderKit through an Objective-C shim. RuntimeShim alone owns responsibility/sandbox SPI. Every worker handles one request and exits; there is no direct-native fallback when isolation fails. Build IDs detect accidental mismatch, not malicious same-user tampering.

Production size for the earlier sparse-list/query revision, measured with `find Sources -type f ... | xargs wc -l`: implementation files (Swift/ObjC/C) **4,895 → 4,928 (+33, 0.7%)**; including headers **4,995 → 5,030 (+35)**. The net-reduction target was not reached: typed sparse-list/query fields and the separate native section/tag entry points slightly outweigh the removed wiring. No source was moved into tests or compressed merely to change the count.

Section-edit lane offline verification on 2026-11-01: **152 tests passed** (Runtime 15 / Native 55 / Core 49 / CLI+facade+MCP 33) using the Contract's explicit Swift Testing macro-plugin flags, plus `git diff --check`. Parser/facade/Core/native-adapter tests cover name-only, order-only and combined edits, pre-mutation validation and omitted attributes. The adapter double records one `updateSection` call; this is not a new live-save or iCloud claim. Isolated lane production size before merging main, versus `e02a973`: **4,924 → 4,945 (+21)** implementation lines, **5,026 → 5,047 (+21)** including headers. Aggregate interface reduction is measured after the parallel lanes merge; no code was minified or relocated.

Prior signed releases passed scoped live CLI/MCP mutation/recovery checks. See the [coverage record](docs/coverage.md) for build-specific evidence and remaining limits. Explicit image-byte read permission remediation and cross-device iCloud delivery remain unresolved.
