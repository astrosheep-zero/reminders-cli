import Foundation
import Darwin
import ReminderCore
import ReminderRuntime
import ReminderNative
import ReminderFacade
import ReminderMCP

func worker() -> Int32 {
    do {
        let channel = try WorkerChannel(buildID: BuildIdentity.current)
        let data = try channel.readRequest()
        let request: WorkerRequest
        do { request = try JSONDecoder().decode(WorkerRequest.self, from: data) }
        catch {
            let response = WorkerResponse.operation(ExecutionResult(status: .failed, error: Failure(.invalidInput, "Malformed typed worker request")))
            try channel.finish(result: JSONEncoder().encode(response))
            return 0
        }
        let composition = WorkerComposition(
            backend: { NativeReminderBackend() },
            diagnose: { allowProbe in
                Doctor.diagnose(authorization: NativeReminderBackend.authorizationStatus(), capabilities: NativeReminderBackend.capabilities(), allowProbe: allowProbe) {
                    _ = try NativeReminderBackend().reminder(id: "00000000-0000-0000-0000-000000000000")
                }
            },
            authorize: {
                guard try NativeReminderBackend.requestAuthorization() else {
                    throw Failure(.permission, "Reminders full access was not granted. Run doctor to inspect authorization.")
                }
            }
        )
        let response = composition.execute(request, beforeMutation: { try channel.mutationStarted() })
        try channel.finish(result: JSONEncoder().encode(response))
        return 0
    } catch {
        // Do not emit a definite-failure Core envelope after a possible save/authorization change.
        writeError("Worker channel stopped: \(error)\n")
        return 6
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["mcp"] {
    let service = MCPFrontend()
    let interrupts = FrontendInterrupts { Task { await service.stop() } }
    do { try await service.run(); withExtendedLifetime(interrupts) {}; exit(0) }
    catch { writeError("MCP stopped: \(error)\n"); await service.stop(); exit(6) }
}
exit(arguments == ["--worker"] ? worker() : frontend(arguments))
