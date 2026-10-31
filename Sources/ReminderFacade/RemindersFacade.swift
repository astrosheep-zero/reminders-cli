import Foundation
import ReminderCore
import ReminderRuntime

/// Shared frontend boundary. All data and authorization work crosses Runtime;
/// Native construction is confined to WorkerComposition inside --worker.
public final class RemindersFacade: @unchecked Sendable {
    private let client: RuntimeClient
    private let buildID: String
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "reminder.facade.operations", qos: .userInitiated)
    private var requests: [UUID: RuntimeCancellation] = [:]
    private var stopped = false
    public init(client: RuntimeClient = RuntimeClient(), buildID: String = BuildIdentity.current) {
        self.client = client; self.buildID = buildID
    }
    public func execute(_ request: WorkerRequest, projection: String? = nil, cancellation: RuntimeCancellation? = nil) -> OutputEnvelope {
        queue.sync { perform(request, projection: projection, cancellation: cancellation) }
    }
    private func perform(_ request: WorkerRequest, projection: String?, cancellation: RuntimeCancellation?) -> OutputEnvelope {
        do {
            let deadline = if case .setup = request { RuntimeLimits.setupDeadline } else { RuntimeLimits.defaultDeadline }
            let reply = client.execute(request: try JSONEncoder().encode(request), buildID: buildID, deadline: deadline, cancellation: cancellation)
            if !reply.diagnostics.isEmpty { try? FileHandle.standardError.write(contentsOf: reply.diagnostics) }
            return Presentation.transport(reply, request: request, projection: projection)
        } catch { return .failure(error as? Failure ?? Failure(.io, String(describing: error))) }
    }
    public func call(_ name: String, arguments: [String: JSONValue]) async -> OutputEnvelope {
        let operation: PreparedOperation
        do { operation = try FacadeOperations.prepare(name, arguments: arguments) }
        catch { return .failure(error as? Failure ?? invalid(String(describing: error))) }
        let id = UUID(), cancellation = RuntimeCancellation()
        lock.withLock { if stopped { cancellation.cancel() }; requests[id] = cancellation }
        defer { _ = lock.withLock { requests.removeValue(forKey: id) } }
        return await withTaskCancellationHandler {
            // Serialize data operations away from the SDK receive loop. A queued cancellation
            // reaches Runtime's pre-spawn check, so it can never become a delayed write.
            await withCheckedContinuation { continuation in
                queue.async { continuation.resume(returning: self.perform(operation.request, projection: operation.projection, cancellation: cancellation)) }
            }
        } onCancel: { cancellation.cancel() }
    }
    /// EOF/signals cancel and reap workers before the stdio frontend exits.
    public func shutdown() async {
        lock.withLock { stopped = true; requests.values.forEach { $0.cancel() } }
        while lock.withLock({ !requests.isEmpty }) { try? await Task.sleep(for: .milliseconds(10)) }
    }
}
