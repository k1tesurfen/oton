import Foundation

/// A JSON value, so responses can carry arbitrary data and `--json` prints them verbatim.
public enum JSON: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([JSON]), object([String: JSON])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public subscript(key: String) -> JSON? { if case .object(let o) = self { return o[key] } else { return nil } }
    public var string: String? { if case .string(let s) = self { return s } else { return nil } }
    public var number: Double? { if case .number(let n) = self { return n } else { return nil } }
    public var bool: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    public var array: [JSON]? { if case .array(let a) = self { return a } else { return nil } }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
                ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral v: String) { self = .string(v) }
    public init(booleanLiteral v: Bool) { self = .bool(v) }
    public init(integerLiteral v: Int) { self = .number(Double(v)) }
    public init(floatLiteral v: Double) { self = .number(v) }
    public init(dictionaryLiteral elements: (String, JSON)...) { self = .object(Dictionary(uniqueKeysWithValues: elements)) }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(nilLiteral: ()) { self = .null }
}

/// One line from `ot` to the app.
public struct Request: Codable, Sendable {
    public var cmd: String
    public var n: Int?                 // copy <n>
    public var prompt: Bool?           // copy --prompt
    public var open: Bool?             // copy --open
    public var name: String?           // mic <number or name>
    public var id: String?             // retry <id>

    public init(cmd: String, n: Int? = nil, prompt: Bool? = nil, open: Bool? = nil, name: String? = nil, id: String? = nil) {
        self.cmd = cmd
        self.n = n
        self.prompt = prompt
        self.open = open
        self.name = name
        self.id = id
    }
}

/// One line from the app to `ot`. Streaming commands send `final: false` events first.
public struct Response: Codable, Sendable {
    public var ok: Bool
    public var message: String          // human text (what `ot` prints without --json)
    public var error: String?
    public var hint: String?
    public var data: JSON?
    public var final: Bool

    public init(ok: Bool, message: String, error: String? = nil, hint: String? = nil, data: JSON? = nil, final: Bool = true) {
        self.ok = ok
        self.message = message
        self.error = error
        self.hint = hint
        self.data = data
        self.final = final
    }

    public static func success(_ message: String, data: JSON? = nil) -> Response { Response(ok: true, message: message, data: data) }
    public static func failure(_ error: String, hint: String? = nil, data: JSON? = nil) -> Response {
        Response(ok: false, message: error, error: error, hint: hint, data: data)
    }
}

public enum Wire {
    public static func encode<T: Encodable>(_ v: T) -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        var d = (try? enc.encode(v)) ?? Data("{}".utf8)
        d.append(0x0A)
        return d
    }

    public static func decode<T: Decodable>(_ t: T.Type, _ line: Data) throws -> T {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(t, from: line)
    }
}
