import Foundation
import Darwin
import ReminderCore
import ReminderFacade

enum CLIRequest: Equatable {
    case help, mcp
    case worker(WorkerRequest)
}
struct Invocation: Equatable {
    var request: CLIRequest
    var json: Bool
}

enum CLIParser {
    static var help: String {
        """
        reminder — macOS Reminders
        Usage: reminder COMMAND [ARGS] [OPTIONS] [--json]
        IDs or exact names; ambiguous names refuse. Use -- before dash-prefixed positional values.
        \(FacadeOperations.definitions.map { "  \($0.name) \($0.positional.joined(separator: " "))\n    \($0.summary)\n    Options: \($0.options.keys.sorted().map { "--" + $0 }.joined(separator: " "))" }.joined(separator: "\n"))
          setup — explicitly request full Reminders access (only prompting command)
          mcp — official MCP stdio server; no setup tool or automatic permission prompt
        Global: --json, --help. Typed JSON: docs/facade-api.md; tagged enums use kind/value, not Swift _0.
        Exit: 0 ok; 1 input; 2 missing/ambiguous/conflict; 3 permission/sandbox;
              4 unsupported; 5 outcome unknown (DO NOT blindly retry); 6 backend/io/internal.
        """
    }
    static func parse(_ arguments: [String], readImage: (String) throws -> Data = readImage) throws -> Invocation {
        var args = arguments
        let end = args.firstIndex(of: "--") ?? args.count
        let json = args.prefix(end).contains("--json"), help = args.prefix(end).contains("--help")
        args = args.enumerated().filter { !($0.offset < end && $0.element == "--json") }.map(\.element)
        if args.isEmpty || args == ["help"] || help { return Invocation(request: .help, json: json) }
        let special: [String: CLIRequest] = ["setup": .worker(.setup), "doctor": .worker(.doctor), "mcp": .mcp]
        var name = args.removeFirst()
        if let request = special[name] {
            guard args.isEmpty, name != "mcp" || !json else { throw invalid("\(name) takes no options") }
            return Invocation(request: request, json: json)
        }
        if let action = args.first, FacadeOperations.definitions.contains(where: { $0.name == name + " " + action }) { name += " " + args.removeFirst() }
        guard let spec = FacadeOperations.definitions.first(where: { $0.name == name }) else { throw invalid("Unknown command: \(name)") }
        var input: [String: JSONValue] = [:], seen: Set<String> = [], positional: [String] = [], literal = false
        var imagePath: String?, imageType: String?
        while !args.isEmpty {
            let arg = args.removeFirst()
            if arg == "--", !literal { literal = true; continue }
            if !literal, arg.hasPrefix("--") {
                let option = String(arg.dropFirst(2))
                guard let key = spec.options[option], seen.insert(key).inserted else { throw invalid("Unknown or duplicate option \(arg)") }
                if spec.isSwitch(key) { input[key] = .bool(true); continue }
                guard let text = args.first, !text.hasPrefix("--"), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw invalid("Missing value for \(arg)") }
                args.removeFirst()
                if key == "image" { imagePath = text }
                else if key == "image-type" { imageType = text }
                else if option.hasSuffix("-json") {
                    do { input[key] = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }
                    catch { throw invalid("Malformed JSON for --\(option): \(error)") }
                }
                else if ["clear", "removeImageIDs"].contains(key) { input[key] = .array(text.split(separator: ",", omittingEmptySubsequences: false).map { .string(String($0)) }) }
                else if key == "limit" {
                    guard let count = Int(text), count > 0 else { throw invalid("--limit must be positive") }; input[key] = .number(Decimal(count))
                } else { input[key] = .string(text) }
            } else { positional.append(arg) }
        }
        guard positional.count == spec.positional.count else { throw invalid("\(name) expects \(spec.positional.count) positional arguments") }
        for (key, value) in zip(spec.positional, positional) { input[key] = .string(value) }
        if let imagePath {
            guard let imageType, imageType.hasPrefix("image/") else { throw invalid("--image requires --image-type image/TYPE") }
            input["images"] = try Presentation.value([ImageInput(fileName: URL(fileURLWithPath: imagePath).lastPathComponent, contentType: imageType, bytes: readImage(imagePath))])
        } else if imageType != nil { throw invalid("--image-type requires --image") }
        return Invocation(request: .worker(try FacadeOperations.prepare(spec.toolName, arguments: input)), json: json)
    }
    static func invalid(_ message: String) -> Failure { ReminderFacade.invalid(message) }
    static func readImage(_ path: String) throws -> Data {
        do {
            guard !path.contains("\0") else { throw invalid("Image path contains NUL") }
            let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(handle.fileDescriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw invalid("Image input must be a regular file") }
            let data = try handle.read(upToCount: 16 * 1024 * 1024 + 1) ?? Data()
            guard !data.isEmpty, data.count <= 16 * 1024 * 1024 else { throw invalid("Image empty or larger than 16 MiB") }
            return data
        } catch let error as Failure { throw error }
        catch { throw Failure(.io, "Cannot read image: \(error.localizedDescription)") }
    }
}
