import Foundation

// Compiled into an independent fixture executable linked to the public runtime module.
// No native/Core/permission APIs are used; malformed modes deliberately violate the wire.
let workerFixtureSource = #"""
import Foundation
import Darwin
import ReminderRuntime

let mode = CommandLine.arguments[1]
let artifact = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ""
func raw(_ text: String) { FileHandle.standardOutput.write(Data(text.utf8)) }
func mark() { if !artifact.isEmpty { try! Data("dispatched".utf8).write(to: URL(fileURLWithPath: artifact)) } }
func holdForever() -> Never { while true { usleep(10000) } }
func spam() {
    let block = Data(repeating: 120, count: 65536)
    for _ in 0..<32 { FileHandle.standardError.write(block) }
}

if mode == "mismatch" || mode == "badHello" || mode == "noHello" {
    signal(SIGTERM, SIG_IGN) // Allow the closed request pipe to be observed before forced reap.
    if mode == "mismatch" { _ = try WorkerChannel(buildID: "other") }
    if mode == "badHello" { raw("{broken}\n") }
    if mode == "noHello" { raw("{\"type\":\"mutationStarted\"}\n") }
    if !FileHandle.standardInput.readDataToEndOfFile().isEmpty { mark() }
    exit(0)
}
if mode == "startupHang" { holdForever() }
if mode == "stderr" || mode == "duplex" { spam() }
if mode == "oversizedHello" {
    FileHandle.standardOutput.write(Data(repeating: 97, count: RuntimeLimits.frameBytes + 1))
    holdForever()
}
let worker = try WorkerChannel(buildID: "fixture-v1")
if mode == "noRead" {
    spam()
    holdForever()
}
let request = try worker.readRequest()
if mode == "requestArtifact" { mark() }
if mode == "crashBefore" { kill(getpid(), SIGKILL); holdForever() }
if mode == "hangBefore" { mark(); holdForever() }
if mode == "crashAfter" || mode == "hangAfter" || mode == "partialAfter" || mode == "badAfter" || mode == "duplicateMutation" {
    try worker.mutationStarted()
}
if mode == "crashAfter" { kill(getpid(), SIGKILL); holdForever() }
if mode == "hangAfter" { mark(); holdForever() }
if mode == "partialAfter" { raw("{\"type\":\"result\",\"payload\":\""); exit(0) }
if mode == "badAfter" { raw("garbage\n"); exit(0) }
if mode == "corruptThenMarker" {
    raw("native-output-without-newline")
    try worker.mutationStarted()
    mark() // Represents a save after the marker was fully committed.
    holdForever()
}
if mode == "duplicateMutation" { raw("{\"type\":\"mutationStarted\"}\n"); exit(0) }
if mode == "badPayload" { raw("{\"type\":\"result\",\"payload\":\"!!!!\"}\n"); exit(0) }
if mode == "extraField" { raw("{\"type\":\"result\",\"payload\":\"\",\"alien\":true}\n"); exit(0) }
if mode == "duplicateKeys" { raw("{\"type\":\"result\",\"type\":\"result\",\"payload\":\"\"}\n"); exit(0) }
if mode == "duplicateHello" { raw("{\"type\":\"hello\",\"buildID\":\"fixture-v1\"}\n"); exit(0) }
if mode == "oversizedResult" {
    FileHandle.standardOutput.write(Data(repeating: 97, count: RuntimeLimits.frameBytes + 1))
    holdForever()
}
if mode == "workerAPI" {
    do { _ = try worker.readRequest(); exit(21) } catch RuntimeIssue.unexpectedFrame {}
    try worker.mutationStarted()
    try worker.mutationStarted()
    try worker.finish(result: request)
    do { try worker.finish(result: request); exit(22) } catch RuntimeIssue.unexpectedFrame {}
    do { try worker.mutationStarted(); exit(23) } catch RuntimeIssue.unexpectedFrame {}
    exit(0)
}
if mode == "workerOversizeAfter" {
    try worker.mutationStarted()
    do {
        try worker.finish(result: Data(repeating: 0, count: RuntimeLimits.payloadBytes + 1))
        exit(24)
    } catch RuntimeIssue.oversizedPayload { exit(0) }
}
if mode == "duplex" { spam() }
if mode == "mutation" || mode == "mutatingTrailing" || mode == "mutatingDuplicateResult" { try worker.mutationStarted() }
if mode == "descriptor" {
    let descriptor = Int32(String(decoding: request, as: UTF8.self))!
    let closed = fcntl(descriptor, F_GETFD) < 0 && errno == EBADF
    try worker.finish(result: Data((closed ? "closed" : "leaked").utf8))
} else if mode == "environment" {
    let keys = ProcessInfo.processInfo.environment.keys.filter { $0.hasPrefix("DYLD_") }
    try worker.finish(result: Data(keys.joined(separator: ",").utf8))
} else {
    try worker.finish(result: request)
}
if mode == "nonzeroAfter" { exit(17) }
if mode == "trailingAfter" || mode == "mutatingTrailing" { raw("{broken}\n") }
if mode == "partialTrailing" { raw("unfinished") }
if mode == "duplicateResult" || mode == "mutatingDuplicateResult" { raw("{\"type\":\"result\",\"payload\":\"eA==\"}\n") }
if mode == "hangResult" { holdForever() }
"""#
