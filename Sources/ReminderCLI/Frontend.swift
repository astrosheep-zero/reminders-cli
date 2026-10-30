import Foundation
import Dispatch
import Darwin
import ReminderCore
import ReminderRuntime

func writeError(_ text: String) { try? FileHandle.standardError.write(contentsOf: Data(text.utf8)) }

/// Dispatch handlers run on a queue, not inside a raw signal handler. Runtime owns kill/reap.
final class FrontendInterrupts {
    let cancellation = RuntimeCancellation()
    private var sources: [DispatchSourceSignal] = []
    private let oldInterrupt: sig_t?
    private let oldTerminate: sig_t?
    init() {
        oldInterrupt = signal(SIGINT, SIG_IGN)
        oldTerminate = signal(SIGTERM, SIG_IGN)
        let token = cancellation
        for number in [SIGINT, SIGTERM] {
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .userInitiated))
            source.setEventHandler { token.cancel() }
            source.resume(); sources.append(source)
        }
    }
    deinit {
        sources.forEach { $0.cancel() }
        signal(SIGINT, oldInterrupt); signal(SIGTERM, oldTerminate)
    }
}

/// The client/buildID parameters are deterministic test seams; the shipped entry uses the same executable.
func frontend(_ arguments: [String], client: RuntimeClient = RuntimeClient(), buildID: String = BuildIdentity.current) -> Int32 {
    let prefix = arguments.prefix(while: { $0 != "--" })
    let wantsJSON = prefix.contains("--json")
    let output: OutputEnvelope
    do {
        let invocation = try CLIParser.parse(arguments)
        let request: WorkerRequest
        let projection: String?
        let deadline: TimeInterval
        switch invocation.request {
        case .help:
            if !invocation.json {
                try FileHandle.standardOutput.write(contentsOf: Data((CLIParser.help + "\n").utf8))
                return 0
            }
            let helpOutput = OutputEnvelope(status: .ok, result: .object(["kind": .string("help"), "help": .string(CLIParser.help)]), warnings: [])
            try FileHandle.standardOutput.write(contentsOf: helpOutput.json() + Data([10]))
            return 0
        case .setup: request = .setup; projection = nil; deadline = RuntimeLimits.setupDeadline
        case .doctor: request = .doctor; projection = nil; deadline = RuntimeLimits.defaultDeadline
        case .operation(let command, let view): request = .operation(command); projection = view; deadline = RuntimeLimits.defaultDeadline
        }
        let data = try JSONEncoder().encode(request)
        let interrupts = FrontendInterrupts()
        let reply = withExtendedLifetime(interrupts) {
            client.execute(request: data, buildID: buildID, deadline: deadline, cancellation: interrupts.cancellation)
        }
        if !reply.diagnostics.isEmpty { try? FileHandle.standardError.write(contentsOf: reply.diagnostics) }
        output = Presentation.transport(reply, request: request, projection: projection)
    } catch {
        output = .failure(error as? Failure ?? Failure(.io, String(describing: error)))
    }
    do {
        if wantsJSON { try FileHandle.standardOutput.write(contentsOf: output.json() + Data([10])) }
        else {
            let handle = output.status == .ok ? FileHandle.standardOutput : FileHandle.standardError
            try handle.write(contentsOf: Data(output.text().utf8))
        }
        return output.exitStatus
    } catch {
        writeError("Output unavailable: \(error). A submitted operation may have taken effect; do not blindly retry.\n")
        return 5
    }
}
