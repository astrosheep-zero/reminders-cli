# Shared Swift facade and MCP API

CLI and MCP are peer frontends over `ReminderFacade`. MCP uses the official `modelcontextprotocol/swift-sdk` **0.12.1**, not a handwritten JSON-RPC implementation or a CLI subprocess wrapper. Run `reminder mcp` for stdio. Keep stdout exclusively for the SDK protocol; worker diagnostics go to stderr.

## Boundaries

- `FacadeOperations.definitions` is the single registry for operation names, CLI option adaptation, summaries, input schemas and typed dispatch closures. `Schema` generates discovery schemas and validates/converts the same shapes at invocation time.
- `FacadeOperations.prepare(_:arguments:)` returns a typed `PreparedOperation` (`WorkerRequest` plus an optional catalog projection). Unknown operations, unknown/nested fields, wrong primitive types, nulls, missing arguments and false required confirmations refuse before Runtime dispatch.
- `RemindersFacade.call(_:arguments:)` is the cancellable async entry. The CLI's blocking `execute(_:projection:cancellation:)` shares the same serial dispatch queue, Runtime execution and output mapping. Do not call the blocking entry from an SDK handler.
- `WorkerComposition` is the worker-side boundary: it alone composes typed Core Operations with the injected backend. Production injects Native only in the same executable's internal `--worker` branch. Core remains independent of the SDK and Runtime remains independent of Core.
- Worker `Command`, `Change`, `WorkerRequest` and `WorkerResponse` Codable enum representations are internal transport details. They are not MCP/CLI JSON syntax. Native's creation-to-patch lift also uses this private typed representation; no generic native RPC or selector input is exposed.

Each worker still handles exactly one request. Build identity checks, required disclaimed spawn, bounded pipes/deadlines, version checks, journal-before-delete, native preflight and request-owned receipts remain in force. No direct-Native fallback or automatic write retry exists.

## Tool discovery

The SDK negotiates MCP **2025-11-25**, advertises tools only and registers `tools/list` and `tools/call`. Server version follows `CFBundleShortVersionString`, with development fallback `0.1.0`. There are no permission-requesting resources or prompts. The fixed tool list is a single page; an unknown cursor is rejected.

There are **36 tools**, with typed object schemas, required properties, closed nested objects, enum/variant alternatives, descriptions and conservative read-only/destructive/idempotency annotations:

| Family | Tool names |
|---|---|
| Diagnostics | `doctor` |
| Reminders | `find`, `show`, `add`, `edit`, `done`, `delete`, `deleted`, `restore`, `image` |
| Catalog | `catalog`, `lists`, `groups`, `sections`, `tags`, `smart_lists`, `templates` |
| Lists | `lists_add`, `lists_edit`, `lists_delete`, `lists_clear_completed` |
| Groups | `groups_add`, `groups_rename`, `groups_delete` |
| Sections | `sections_add`, `sections_rename`, `sections_move`, `sections_delete` |
| Tags | `tags_rename`, `tags_delete` |
| Smart lists | `smart_lists_add`, `smart_lists_edit`, `smart_lists_delete` |
| Templates | `templates_add`, `templates_use`, `templates_delete` |

`setup` is deliberately **not** a tool. Invoke CLI `reminder setup` explicitly when permission is needed; no ordinary operation or MCP startup requests it. `doctor` may perform the existing sentinel UUID read only when full access is already granted, and a successful diagnostic envelope does not mean all checks passed. `deleted` can reconcile its journal, so it is not annotated read-only.

CLI names use spaces/hyphens (`smart-lists edit`); MCP names replace both with underscores (`smart_lists_edit`). CLI retains all command families and image-file adaptation. `--help` derives operation documentation from the shared registry.

## Stable JSON values

Public enums are objects with `kind`. An unlabeled associated value is named **`value`**, never `_0`. Objects with named fields keep those field names. Empty cases need only `kind`. Null is not a clearing instruction.

```json
{"kind":"date","value":{"year":2030,"month":2,"day":3}}
{"kind":"localDateTime","value":{"year":2030,"month":2,"day":3},"hour":9,"minute":30,"second":0}
{"kind":"before","value":"NEIGHBOR_ID"}
{"kind":"after","value":"NEIGHBOR_ID"}
{"kind":"count","value":5}
{"kind":"until","value":{"year":2031,"month":1,"day":1}}
{"kind":"place","title":"Station","latitude":31.2,"longitude":121.5,"radius":100,"when":"arriving"}
{"kind":"gettingInCar"}
{"kind":"gettingOutOfCar"}
```

Dates are Gregorian civil components, not UTC instants. Place alerts optionally include `address`; `when` is `arriving` or `leaving`. Contact alerts are `{ "phones": [...], "emails": [...] }`, from explicit inputs, never Contacts lookup.

Recurrence is `{frequency, interval, weekdays, monthDays, months, end?}`. Frequency is `hourly/daily/weekly/monthly/yearly`; weekdays contain `{day, ordinal?}` with Sunday=1 through Saturday=7. `end` uses count/until above. Early alerts contain `{before, unit}`; units are `minutes/hours/days/weeks/months`. Core validation still enforces date/range/recurrence/urgent/relationship restrictions.

Smart filters use these stable shapes (unknown native filters are output-only):

```json
[
  {"kind":"tags","value":["work"],"match":"any"},
  {"kind":"date","value":{"kind":"any"}},
  {"kind":"date","value":{"kind":"range","from":{"year":2030,"month":1,"day":1},"before":{"year":2030,"month":2,"day":1}}},
  {"kind":"date","value":{"kind":"relative","past":0,"future":7,"unit":"days"}},
  {"kind":"priorities","value":["high","medium"]},
  {"kind":"flagged","value":true},
  {"kind":"lists","value":["LIST_ID"]},
  {"kind":"location","value":"gettingInCar"}
]
```

Date filters also model `none`/`overdue`, and time filters model `{kind:"time",fromHour,fromMinute,toHour,toMinute}`. A schema describing a Core value is not a claim that every native shape/account supports it: arbitrary time windows, overdue-only filters, bidirectional/minute relative ranges and coordinate-free place filters remain explicitly unsupported. Location filter strings are `any/none/arriving/leaving/gettingInCar/gettingOutOfCar`. An output-only opaque filter is `{kind:"unknown",key,payload}` with base64 payload. Such filters are preserved on read, excluded from writable discovery schemas and refused on submission; smart lists containing them cannot be edited even by dropping the unknown filter.

## Operation arguments

| Operation | Arguments |
|---|---|
| `find` | Optional `query` object, with optional top-level `text`, `list`, `limit` overrides |
| `show` | `id` (ID or exact title) |
| `add` | `title`, `list`, optional `fields`, `images` |
| `edit` | `id`, `version`, optional `set`, `clear`, `images`, `removeImageIDs`; at least one change |
| `done` | `id`, `version`, optional `undo` (default false) |
| `delete` | `id`, `version`; includes known children |
| `restore` | `id`, optional `list`; saved destination required if list is omitted |
| `image` | `id`, `imageID`; explicit byte read |
| `sections` | Optional `list` projection filter |
| Container add | `name`; sections/templates also require `list`; lists allow `fields`; smart lists require `definition`; templates allow `includeCompleted` |
| List edit | `id`, full `fields` (`name`, `pinned`, `kind`, `sort` required) |
| Smart-list edit | `id`, full `definition` (`id`, `name`, `match`, `filters` required) |
| Group/tag rename | `id`, `name` (tag `id` is its exact tag name) |
| Section rename/move | `id`, `list`, plus `name` or tagged `position` respectively |
| Container delete / clear-completed | `id`, `confirmed:true`; sections also require `list` |
| Template use | `id`, optional `name` for the new list |
| Other listings / `catalog` / `doctor` / `deleted` | Empty object |

Reminder `fields`/`set` keys: `title`, `listID`, `notes`, `due`, `start`, `recurrence`, `earlyAlerts`, `location`, `contact`, `url`, `priority`, `flagged`, `urgent`, `completed`, `tags`, `parentID`, `sectionID`, `position`, `assigneeID`. Priority is `none/low/medium/high`; flags are booleans and tags are string arrays. Creation fields overlay Core defaults but cannot override positional/top-level title or list identity. Edit sets preserve false/empty string/empty array; `clear` is an array of field names, disjoint from `set`. Missing fields remain absent. List edits are full replacements, except omitted position is a write-only no-ordering directive, not an erase request.

Query keys: `text`, `list`, `smartList`, `section`, `includeCompleted`, `flagged`, `urgent`, `repeating`, `hasLocation`, `assigneeID`, `tags`, `dueOnOrAfter`, `dueBefore`, `limit`. Defaults exclude completed and limit to 100.

List fields: `name`, `color`, `icon`, `groupID`, `pinned`, `kind` (`standard/groceries`), `sort` (`manual/due/creation/priority/title`), `position`. Smart definitions: `id`, `name`, optional `color`/`icon`, `match` (`all/any`), `filters`. Creation defaults are retained for omitted fields. Full replacements omit optional fields to clear them, not null.

Images are `{fileName, contentType, bytes}` with base64 `bytes`; MCP never reads caller-supplied filesystem paths. CLI `--image` reads a bounded regular file in the frontend, converts it to exactly this payload and drops the original path. Runtime requests/results are capped at 16 MiB before MCP wrapping; JSON/base64 overhead reduces usable attachment bytes. Ordinary reads return image metadata only. Explicit image read still has the separately recorded native permission limitation (`NSCocoaErrorDomain/257`); this revision neither supplies an unverified authorization mechanism nor claims it repaired, and does not prescribe Full Disk Access as a fix.

Examples of `tools/call` arguments:

```json
{"name":"add","arguments":{"title":"Buy fish","list":"Inbox","fields":{"due":{"kind":"date","value":{"year":2030,"month":2,"day":3}}}}}
{"name":"edit","arguments":{"id":"REMINDER_ID","version":"VERSION","set":{"flagged":false,"notes":""},"clear":["due"]}}
{"name":"sections_move","arguments":{"id":"SECTION_ID","list":"LIST_ID","position":{"kind":"after","value":"OTHER_SECTION_ID"}}}
```

## Results, cancellation and uncertainty

`CallTool.Result.structuredContent` is the same stable envelope as CLI `--json`. A text content item contains the same JSON for clients without structured-content support. `isError` is true for both failed and unknown outcomes.

```json
{"status":"ok","result":{"kind":"reminders","reminders":[{"id":"R","fields":{"title":"T","listID":"L"},"images":[],"childIDs":[],"version":"TOKEN"}]},"warnings":[]}
{"status":"failed","error":{"code":"conflict","message":"Reminder changed","affectedIDs":[]},"warnings":[]}
{"status":"unknown","error":{"code":"outcomeUnknown","message":"Final answer unavailable","affectedIDs":["R"]},"warnings":["Inspect state before retrying."]}
```

The first example abbreviates default fields; actual reminders include all required Core fields. Result kinds remain `reminders`, `mutation`, `catalog`, `lists/groups/sections/tags/smartLists/templates`, `deleted`, `image`, `diagnostics`, and CLI-only `help`. Mutations retain affected IDs, computed count, versioned reminders and lists. Deletion output has explicit `scope:"toolOnly"` and entries, not all-system Recently Deleted. Versions still hash Core's canonical visible state; changing the public enum spelling does not change the token algorithm. Internal mutation payloads no longer redundantly encode computed count; the facade computes it once for public output.

Swift task cancellation from the official SDK runs the facade's cancellation handler, including while queued. Active Runtime polling observes the token, stops/reaps the worker and drains pending pipe bytes so a just-written mutation marker cannot be lost. Pending canceled calls reach Runtime's pre-spawn check and cannot become delayed writes. EOF/signals cancel and drain active/queued calls before frontend exit. Per-worker deadlines are 30 seconds (explicit CLI setup: 120); queue wait does not extend the worker's own deadline.

A cancellation before possible mutation is a definite pre-mutation failure. After mutation, missing/malformed/contradictory output remains `unknown`, not definite failure. A clean authoritative final result can still win a cancellation race. The official SDK client intentionally cancels its waiter and ignores late responses after cancellation, so a client may never receive the final unknown envelope: cancellation is advisory, **not rollback or proof of no save**. Re-read state and affected IDs before retrying; never blindly retry creation/deletion. Local acceptance is not proof of iCloud delivery.

## Verification and SDK provenance

`Package.swift` pins the official SDK tag 0.12.1 (`a0ae212ebf6eab5f754c3129608bc5557637e605`). Integration was checked against its README and actual `Server.swift`, `Tools.swift`, `Client.swift`, `StdioTransport.swift`, `InMemoryTransport.swift` and lifecycle/cancellation APIs. The SDK owns initialize/version negotiation, framing, request handling and cancellation notifications. Its server stop does not itself reap application workers, so facade shutdown explicitly owns that responsibility.

Offline tests use the official SDK client/server and transports, a genuine stdio executable for initialize/list/invalid-call/EOF, and injected one-shot subprocesses running the actual facade/Core/Runtime composition for success, lost/corrupt/wrong/contradictory results, cancellation and queued cancellation. These are not simulated old API shims. No native store, setup, signing, keychain operation or live mutation is part of these tests.

Collections 1.6.0 and all resolved manifests support the advertised Swift 6.2 floor; unrestricted Collections 1.7.5 would require 6.4. Verification ran on the installed Swift 6.4.2 compiler, not an independently installed 6.2 compiler. A real Swift 6.2 toolchain build remains unverified. Prior broad signed-native evidence belongs to the older build identified in [coverage](coverage.md). A subsequent signed Release build passed the focused CLI/MCP live regression recorded there; it does not establish every native/account capability or resolve explicit image-byte access.
