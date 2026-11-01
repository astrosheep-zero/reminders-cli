import Foundation
import Darwin
import MCP
import ReminderFacade

/// Protocol handling belongs to the official SDK; this adapter only maps tools to the facade.
public struct MCPFrontend: Sendable {
    public let server: Server
    public let facade: RemindersFacade
    public init(facade: RemindersFacade = RemindersFacade()) {
        self.facade = facade
        server = Server(name: "reminder", version: BuildIdentity.version, instructions:
            "Local macOS Reminders. Use show/find versions for edits. Only CLI setup can prompt for access. Writes are never retried; unknown or cancelled writes may have happened. Inspect state/affected IDs before retrying. Local save is not proof of iCloud sync.",
            capabilities: .init(tools: .init(listChanged: false)), configuration: .strict)
    }
    public func start(transport: any Transport) async throws {
        let tools = try FacadeOperations.definitions.map { definition in
            Tool(name: definition.toolName, description: definition.summary,
                inputSchema: try Value(definition.inputSchema),
                annotations: .init(readOnlyHint: definition.readOnly, destructiveHint: definition.destructive,
                    idempotentHint: definition.idempotent, openWorldHint: false))
        }
        await server.withMethodHandler(ListTools.self) { params in
            guard params.cursor == nil else { throw MCPError.invalidParams("This fixed tool list has no further pages") }
            return .init(tools: tools)
        }
        await server.withMethodHandler(CallTool.self) { params in
            let arguments = try JSONDecoder().decode([String: JSONValue].self, from: JSONEncoder().encode(params.arguments ?? [:]))
            let output = await facade.call(params.name, arguments: arguments)
            do {
                let data = try output.json()
                return .init(content: [.text(text: String(decoding: data, as: UTF8.self), annotations: nil, _meta: nil)],
                    structuredContent: Optional.some(try JSONDecoder().decode(Value.self, from: data)), isError: output.status != .ok)
            } catch {
                // Never turn loss of a possibly-mutating result into a definite JSON-RPC failure.
                let unknown = OutputEnvelope.unknown("MCP could not serialize the final result; inspect state before retrying")
                return try .init(content: [.text(text: String(decoding: unknown.json(), as: UTF8.self), annotations: nil, _meta: nil)], structuredContent: unknown, isError: true)
            }
        }
        try await server.start(transport: transport)
    }
    public func stop() async {
        await server.stop()
        await facade.shutdown()
    }
    public func run() async throws {
        signal(SIGPIPE, SIG_IGN) // Let EPIPE reach the SDK; EOF shutdown must cancel/reap workers.
        try await start(transport: StdioTransport())
        await server.waitUntilCompleted()
        await stop()
    }
}
