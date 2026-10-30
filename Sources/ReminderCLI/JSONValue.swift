import Foundation

/// A closed JSON syntax tree for typed input overlays and stable output. Not a native RPC surface.
indirect enum JSONValue: Codable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Decimal), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Decimal.self) { self = .number(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    static func properties<T: Encodable>(_ value: T) throws -> [String: JSONValue] {
        guard case .object(let object) = try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value)) else {
            throw CLIParser.invalid("Expected typed object")
        }
        return object
    }
    /// Codable normally ignores unknown keys. Refuse keys that the typed roundtrip discarded.
    func checkKeys(against canonical: JSONValue, path: String = "") throws {
        switch (self, canonical) {
        case (.object(let input), .object(let output)):
            for (key, value) in input {
                guard let other = output[key] else {
                    throw CLIParser.invalid("Unknown or inapplicable JSON field: \(path)\(key)")
                }
                try value.checkKeys(against: other, path: path + key + ".")
            }
        case (.array(let input), .array(let output)):
            for (lhs, rhs) in zip(input, output) { try lhs.checkKeys(against: rhs, path: path) }
        default: break
        }
    }
}
