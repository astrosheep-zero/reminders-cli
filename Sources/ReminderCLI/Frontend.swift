import Foundation
import Dispatch
import Darwin
import ReminderCore
import ReminderRuntime
import ReminderFacade

func writeError(_ text: String) { try? FileHandle.standardError.write(contentsOf: Data(text.utf8)) }

/// Dispatch handlers run on a queue, not inside a raw signal handler. Runtime owns kill/reap.
final class FrontendInterrupts {
    let cancellation = RuntimeCancellation()
    private var sources: [DispatchSourceSignal] = []
    private var originals: [(Int32, sig_t?)] = []
    init(onInterrupt: @escaping @Sendable () -> Void = {}) {
        let token = cancellation
        for number in [SIGINT, SIGTERM] {
            originals.append((number, signal(number, SIG_IGN)))
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .userInitiated))
            source.setEventHandler { token.cancel(); onInterrupt() }
            source.resume(); sources.append(source)
        }
    }
    deinit {
        sources.forEach { $0.cancel() }
        originals.forEach { signal($0.0, $0.1) }
    }
}

/// The client/buildID parameters are deterministic test seams; the shipped entry uses the same executable.
func frontend(_ arguments: [String], client: RuntimeClient = RuntimeClient(), buildID: String = BuildIdentity.current) -> Int32 {
    let prefix = arguments.prefix(while: { $0 != "--" })
    let wantsJSON = prefix.contains("--json")
    let output: OutputEnvelope
    do {
        let invocation = try CLIParser.parse(arguments)
        let request: WorkerRequest?
        switch invocation.request {
        case .help: request = nil
        case .mcp: throw invalid("Run reminder mcp without other arguments")
        case .worker(let value): request = value
        }
        if let request {
            let interrupts = FrontendInterrupts()
            output = withExtendedLifetime(interrupts) {
                RemindersFacade(client: client, buildID: buildID).execute(request, cancellation: interrupts.cancellation)
            }
        } else { output = OutputEnvelope(status: .ok, result: .object(["kind": .string("help"), "help": .string(CLIParser.help)])) }
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
