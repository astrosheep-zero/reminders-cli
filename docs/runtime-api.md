# One-shot Runtime API

`ReminderRuntime` imports only Foundation and RuntimeShim. It knows no Core command,
result, error, or permission type. CLI owns serialization, `--worker` dispatch,
packaging, and translating the opaque result into user output. Swift 6 / macOS 26+
/ Apple silicon; no daemon, network, registry, privileged entitlement, or retry.

## Frontend

```swift
public struct RuntimeClient: Sendable {
    public init(executable: URL? = nil, arguments: [String] = ["--worker"])
    public func execute(
        request: Data,
        buildID: String,
        deadline: TimeInterval = RuntimeLimits.defaultDeadline,
        cancellation: RuntimeCancellation? = nil
    ) -> RuntimeReply
}

public final class RuntimeCancellation: @unchecked Sendable {
    public init()
    public func cancel()
    public var isCancelled: Bool { get }
}
```

`execute` is synchronous; `deadline` is a positive finite duration in seconds,
measured with monotonic uptime from call entry, not an absolute Date. Default is
30 seconds; setup should pass `RuntimeLimits.setupDeadline` (120 seconds).
The duration includes handshake, request IO, response IO, and worker exit.
Cancellation/deadline terminates the process group with SIGTERM, allows 100 ms,
then SIGKILLs and reaps the direct child. Poll responsiveness is at most 20 ms,
plus bounded frame processing and cleanup; this is not a hard real-time guarantee
against kernel stalls. Even successful calls reap the worker before returning.
The caller must not independently waitpid/reap Runtime's children.

Nil executable resolves the current executable using the OS, then canonicalizes
symlinks; it does not trust argv[0], PATH, or the current directory. An injected
absolute file URL/argument array is useful for fixtures and other composition;
it NEVER relaxes disclaimed spawn. Production CLI uses the defaults. No request
bytes are sent until a matching hello has been fully validated. Request stdin is
closed after exactly one line. There is no automatic retry of any operation.

`buildID` is injected by CLI/packaging into both the frontend call and worker
initializer: nonempty, at most 128 UTF-8 bytes, no NUL, compared exactly. Runtime
does not generate it or inspect Info.plist. Equality compares UTF-8 bytes, not
Swift's canonically equivalent Unicode strings. A signed app can supply its unique
`ReminderBuildID` plist key; a development executable can supply a deterministic
dev ID. This detects version mixups; it is NOT cryptographic authentication.

```swift
public struct RuntimeReply: Sendable {
    public enum Outcome: Equatable, Sendable {
        case result(Data)
        case failed(RuntimeIssue)
        case outcomeUnknown(RuntimeIssue)
    }
    public let outcome: Outcome
    public let diagnostics: Data
    public let diagnosticsTruncated: Bool
    public let mutationStarted: Bool
    public let issue: RuntimeIssue?
    public let exitStatus: Int32?
    public let processID: Int32?
}
```

`mutationStarted` records whether the pre-save marker was observed, including on
`.result`. It must survive CLI result decoding: if Core payload decoding fails
with this flag true, CLI must report outcomeUnknown, not a definite no-write
failure. A Runtime `.result` is an authoritative opaque worker reply, **not** a
claim that Core succeeded. Core may encode failure, partial evidence, or unknown.
No final result with a clean stream and no mutation marker is a definite transport
failure; after mutation, missing result, crash, timeout, cancellation, or IO failure
is unknown. Corrupt stdout **after request dispatch** is also conservatively
unknown even if `mutationStarted` is false: corrupted output can hide a marker,
so no marker observed is not proof of no save. Pre-dispatch protocol/build failures
are definite and send no request. Never retry an unknown write automatically.

A normal successful exchange has nil `issue` and exitStatus 0. One valid final
frame followed by clean stdout is authoritative even if the worker later exits
nonzero, is signalled, or has to be stopped at deadline/cancellation: outcome stays
`.result`, with `.workerExited`/`.deadline`/`.cancelled` in `issue`. Exit status is
exit code or 128+signal. But duplicate result, contradictory/out-of-order frames,
malformed frames, or partial trailing stdout **invalidate the stream and discard
the result**: no status-ok is returned. After dispatch this is unknown, with or
without an observed mutation marker. Stderr never invalidates a valid result.
Cleanup drains committed stdout after stopping the worker, including queued
mutation markers, before classifying timeout/cancellation.

Diagnostics are arbitrary bytes, not guaranteed UTF-8. A refusal before spawn has
nil processID/exitStatus; spawned processIDs identify already-reaped children.

`RuntimeIssue` cases are `invalidConfiguration`, `oversizedPayload`,
`spawnRefused(code: Int32, disclaim: Bool)`, `buildMismatch`, `invalidFrame`,
`unexpectedFrame`, `truncatedOutput`, `io(code: Int32)`, `deadline`, `cancelled`,
and `workerExited`. They are transport issues, not Core error codes. The disclaim
flag distinguishes missing/failing responsibility SPI from other spawn failures.

## Worker

```swift
public final class WorkerChannel: @unchecked Sendable {
    public init(buildID: String, input: Int32 = 0, output: Int32 = 1) throws
    public func readRequest() throws -> Data
    public func mutationStarted() throws
    public func finish(result: Data) throws
}
```

The initializer writes hello immediately, before reading any request. Descriptors
are borrowed (not closed by the channel); production uses stdin/stdout. Read one
request, decode Core command, construct native operations, execute once, encode
Core result, finish, and exit. `readRequest` requires EOF after the single request
line and rejects extra requests or trailing bytes. Do not instantiate native stores
or request authorization before handshake/request validation.

Pass `try channel.mutationStarted()` as the synchronous Core pre-save callback.
The marker is fully written **before** this call returns. If it throws, abort the
save; swallowing this error violates the no-false-failure guarantee. Repeated
pre-save callbacks on the same channel are idempotent. `finish` is permitted once,
after reading a request, with or without mutation. Re-reading, finishing twice,
or mutation after finish throws. A read/write/oversize-result failure poisons the
channel. Exit on errors; never improvise another stdout protocol or retry a save.
Only one command is executed; the worker does not loop for more commands.

All channel calls serialize through a lock; do not invoke the callback reentrantly
while another channel call is active. Read/write are intentionally blocking on the
worker; the frontend's bounded transport and termination policy supervise them.
Use stderr exclusively for native diagnostics, never print to stdout.

## Signal / cancellation integration

CLI must install cancellation handling **before** executing. Use a
DispatchSource signal handler on a nonblocked queue to call `token.cancel()`;
ignore the signal's default immediate-termination disposition while that source
is installed. Do not call the lock-taking token API in an async POSIX signal
handler, and do not exit the frontend until `execute` has returned and reaped the
worker. Swift Task cancellation is not implicitly wired to this synchronous API.
SIGINT/SIGTERM integration is CLI-owned. An uncatchable frontend SIGKILL or host
crash cannot run cleanup; Runtime does not claim to prevent that orphan case.

## Wire and bounds

UTF-8 newline-delimited JSON; field sets below are exact. No blank lines, unknown
fields/types, duplicate keys/frames, extra requests, or frames out of order:

```json
{"type":"hello","buildID":"package-build-id"}
{"type":"request","payload":"base64 opaque request"}
{"type":"mutationStarted"}
{"type":"result","payload":"base64 opaque result"}
```

Hello/result/marker are worker stdout; request is frontend stdin. Marker is
optional for reads and appears at most once before result. Decoded request/result
limit is 16 MiB each. Base64 length cap is `4 * ceil(16 MiB / 3)`; entire line cap
excluding newline is that value + 1024 bytes (`RuntimeLimits.frameBytes`). JSON
encoding does not escape slash characters, so worst-case base64 fits this cap.
Diagnostics retain the first 64 KiB, flag truncation, and drain/discard the rest.
Stdout, stderr, and request writes are multiplexed concurrently with nonblocking
parent descriptors and bounded chunks; the line accumulator is capped. A worker
that fills stderr before hello, or while the parent writes a maximum-sized
request, cannot deadlock the pipes. The frontend stops on protocol violations.

## Isolation and observations

RuntimeShim alone resolves the private `responsibility_spawnattrs_setdisclaim`
and `sandbox_check` symbols. Missing or failed disclaim refuses to spawn; there
is no caller-responsibility fallback, including for injected fixtures. Spawn uses
closed-by-default descriptor inheritance and explicit stdin/stdout/stderr pipes,
a new process group, reset cancellation-signal dispositions/mask, and an
environment stripped of all `DYLD_*` entries. Parent
pipe writes suppress SIGPIPE per descriptor, not via process-global handlers.
The group is stopped on all return paths, including leftover cooperative worker
descendants; Runtime is not a sandbox against hostile same-user processes that
escape groups or spoof executables/protocols.

`SandboxState.current` returns `.sandboxed`, `.notSandboxed`, or `.unknown`.
This is best-effort process sandbox detection only. It neither requests nor
infers Reminders authorization. Successful fixture spawn does not verify TCC
responsibility attribution, signed-app identity, entitlements, iCloud delivery,
or live ReminderKit behavior. Those require separately authorized observation.
No live reminders, permission prompts, installation, signing/certificate changes,
or reference-repository modifications are part of Runtime tests.

## Verification

`bash scripts/test.sh --filter ReminderRuntimeTests` is the contract command. Tests compile
an independent fixture executable from the same Runtime/shim sources, import the
public Runtime module, and inject its executable/arguments into the production
client. There is no test-only transport or disclaim bypass. Fixture artifacts are
private temporary files; children are checked for reaping, including failures.

On this host's CLT Swift 6.4, the default swiftbuild backend fails to discover
TestingMacros; the native backend instead fails to import Testing. An explicit
installed-plugin invocation runs the actual tests without changing source
behavior or system settings. Holder's shared `scripts/test.sh` selects the
installed plugin through `xcode-select -p`, disables unavailable XCTest, and
executes genuine `swift test` with these flags:

```sh
swift test --disable-xctest --filter ReminderRuntimeTests \
  -Xswiftc -load-plugin-library \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
```

The original bare `swift test --filter ReminderRuntimeTests` failed on this CLT;
the wrapper command is the amended Verification, not a claim that the bare
command works. Neither invocation verifies live permissions or TCC attribution.
