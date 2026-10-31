# reminder — native Reminders CLI and MCP

A Swift CLI and local MCP server for Apple Reminders. Requires Apple silicon and macOS 26+ with a Swift 6.2+ toolchain. Uses private ReminderKit APIs: buildability is **not** proof that every feature works on your OS/account. See [installation and MCP client setup](docs/install.md), [coverage and unresolved evidence](docs/coverage.md), and [architecture](ARCHITECTURE.md).

## Acknowledgments and license

Thanks to [xiaofeng-han/apple-mcp](https://github.com/xiaofeng-han/apple-mcp) and [viticci/remctl](https://github.com/viticci/remctl) for architectural and private-API research references. Their repositories were inspected read-only as evidence; their implementations are not vendored or copied here. MCP uses the [official Swift SDK](https://github.com/modelcontextprotocol/swift-sdk).

This project's original code is available under the [MIT license](LICENSE). Dependencies retain their own licenses.

## Build and offline verification

```sh
bash scripts/test.sh
swift run reminder --help
bash scripts/build-app.sh
plutil -lint dist/Reminder.app/Contents/Info.plist
codesign --verify --strict dist/Reminder.app
./dist/reminder --help
```

`test.sh` runs the actual Swift Testing suite, with XCTest disabled and the installed TestingMacros plugin explicitly loaded. Plain `swift test` on the tested Command Line Tools installation has a macro discovery/XCTest wiring gap; the wrapper fixes toolchain discovery, not product behavior. Tests use fixtures, never request authorization and never open a real Reminders store. Swift dependencies are pinned in `Package.resolved`; MCP uses official Swift SDK 0.12.1.

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
reminder add 'Buy milk' --list LIST_UUID --fields-json '{"priority":"high","tags":["shopping"],"flagged":true}'
reminder edit REMINDER_UUID --version VERSION --set-json '{"notes":"oat milk","flagged":false}' --clear due,location
reminder done REMINDER_UUID --version VERSION           # --undo marks incomplete
reminder delete REMINDER_UUID --version VERSION         # includes known children in one save
reminder deleted --json                                 # this tool only, not all-system Recently Deleted
reminder restore REMINDER_UUID                          # journal remembers original list
reminder restore REMINDER_UUID --list LIST_UUID         # explicit destination if journal unavailable
reminder image REMINDER_UUID IMAGE_UUID --json          # bytes as base64, not original file path
```

IDs match case-insensitively; names match exactly. Ambiguous names refuse. Versioned reminder output includes `id`, `fields`, `images`, `childIDs`, and `version`. Use the token from the most recent `show`/`find` or mutation result. An edit's missing fields stay unchanged; `--set-json` explicitly sets values (including empty string, empty arrays and false); `--clear field,field` explicitly clears. Do not use null as a substitute for clear. Clearing title/list is invalid. Container edits are **full replacement**, not patches, except list `position` is a write-only ordering directive: omitted/nil means no ordering request, not 'erase manual ordering':

```sh
reminder lists --json                         # lists, default marker and joined shared-list members
reminder lists add 'Work' --fields-json '{"color":"blue","icon":"briefcase","pinned":true,"kind":"standard","sort":"manual"}'
reminder lists edit LIST_UUID --fields-json '{"name":"New work","pinned":false,"kind":"standard","sort":"due"}'
reminder lists clear-completed LIST_UUID --yes
reminder lists delete LIST_UUID --yes
reminder groups add 'Projects'
reminder groups rename GROUP_UUID --name 'Active projects'
reminder groups delete GROUP_UUID --yes       # nonempty groups refuse
reminder sections --list LIST_UUID
reminder sections add 'Next' --list LIST_UUID
reminder sections rename SECTION_UUID --list LIST_UUID --name 'Later'
reminder sections move SECTION_UUID --list LIST_UUID --position-json '{"kind":"after","value":"OTHER_SECTION_UUID"}'
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

Bare `lists/groups/sections/tags/smart-lists/templates` read the Core catalog and project the requested family. Only `tags` (or explicit `catalog --json` for all families) requests tag counts (which requires reminder enumeration); other family listings and ordinary mutation resolution request metadata-only catalogs and intentionally omit tag materialization. `sections --list` filters by a uniquely resolved list. There is no invitation command, permanent purge, broad cleanup command, batch command or generic native invocation. Catalog enumeration may fail if an underlying private capability is unavailable; it must not fabricate an empty catalog.

## Exact typed JSON

Create's `--fields-json` overlays Core defaults on the mandatory positional title and `--list`; it cannot override either identity. Edit's `--set-json` uses the **same field names and value shapes**, without Change wrappers. Omit optional nil values on creation/replacement; do not supply null. The parser translates edit values to Core's explicit set/clear/absent representation. List creation also overlays defaults; full list replacement requires `name`, `pinned`, `kind`, `sort`, with optional fields omitted to clear them. Smart-list creation defaults to an empty id, positional name, `match=all`, empty filters; full replacement requires `id`, `name`, `match`, `filters`.

| Reminder field | JSON value |
|---|---|
| `title`, `listID` | strings; only edits may change them inside JSON |
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

`find --query-json` accepts partial `ReminderQuery`: `text`, `list`, `smartList`, `section`, `includeCompleted`, `flagged`, `urgent`, `repeating`, `hasLocation`, `assigneeID`, `tags`, `dueOnOrAfter`, `dueBefore`, `limit`. Dates use the same tags above; default limit is 100 and completed reminders are excluded. Explicit `--text/--list/--limit` override those query JSON fields.

List fields: `name`, optional `color/icon/groupID/position`, `pinned`, `kind` (`standard/groceries`), `sort` (`manual/due/creation/priority/title`). Colors: `red/orange/yellow/green/light-blue/blue/indigo/pink/purple/brown/gray/rose` or `#RRGGBB`. `position` uses before/after list IDs; `groupID` groups lists. All normal enum restrictions still apply on native support checks.

Smart-list fields: `id`, `name`, optional `color/icon`, `match` (`all/any`), `filters`. Each filter is one tagged value:

```json
[
  {"kind":"tags","value":["work","urgent"],"match":"any"},
  {"kind":"date","value":{"kind":"overdue"}},
  {"kind":"date","value":{"kind":"range","from":{"year":2030,"month":1,"day":1},"before":{"year":2030,"month":2,"day":1}}},
  {"kind":"date","value":{"kind":"relative","past":1,"future":7,"unit":"days"}},
  {"kind":"time","fromHour":9,"fromMinute":0,"toHour":17,"toMinute":30},
  {"kind":"priorities","value":["high","medium"]},
  {"kind":"flagged","value":true},
  {"kind":"lists","value":["LIST_UUID"]},
  {"kind":"location","value":"arriving"}
]
```

Date filters also support `none/any`; location filters support `any/none/arriving/leaving/gettingInCar/gettingOutOfCar`. Unknown native filter payloads are preserved on **read** as `unknown` with key/base64 bytes, but cannot be submitted as writable filters. A smart list already containing unknown filters is read-only: even omitting those filters from a replacement must refuse rather than silently discard native conditions. For fully modeled lists, roundtrip the complete definition from `result.smartLists` into edit. Roundtrip reminders by copying `fields` into `--set-json` only for fields you intend to change; do **not** blindly replace every native field or pass the whole output envelope.

## Stable output and failure semantics

`--json` writes one envelope to stdout, including parser failures and help. Diagnostics use stderr. Optional result/error members are omitted when absent; warnings is always an array:

```json
{"status":"ok","result":{"kind":"reminders","reminders":[{"id":"…","fields":{"title":"…","listID":"…"},"images":[],"childIDs":[],"version":"…"}]},"warnings":[]}
{"status":"failed","error":{"code":"conflict","message":"…","affectedIDs":[]},"warnings":[]}
{"status":"unknown","error":{"code":"outcomeUnknown","message":"…","affectedIDs":[]},"warnings":["Do not blindly retry writes."]}
{"status":"ok","result":{"kind":"deleted","scope":"toolOnly","entries":[]},"warnings":[]}
```

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

Current physical source count: **4,817 production lines**, a net reduction of **2 lines** from the 4,819-line starting worktree while adding MCP. Shared dispatch/schema, native save/receipt handling and ABI checks replace duplicated logic. Tests are counted separately: **2,493 lines**, **110 offline tests passed**. The signed release build passed a scoped live CLI/MCP regression covering discovery, diagnostics, tagged inputs, cross-frontend edits, independent child recovery, recurring completion receipts and image add/remove, with cleanup limited to returned test-list IDs. See the [coverage record](docs/coverage.md) for the exact evidence and remaining limits. Explicit image-byte read permission remediation and cross-device iCloud delivery remain unresolved.
