import Foundation

/// A closed JSON syntax tree for typed input overlays and stable output. Not a native RPC surface.
public indirect enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Decimal), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Decimal.self) { self = .number(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
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
    public static func properties<T: Encodable>(_ value: T) throws -> [String: JSONValue] {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        guard case .object(let object) = try JSONDecoder().decode(Self.self, from: encoder.encode(value)) else {
            throw invalid("Expected typed object")
        }
        return object
    }
}
