import Foundation

/// A loosely typed JSON value for tolerant decoding of provider wire formats.
///
/// Provider protocols evolve faster than we ship; decoding into `JSONValue` and reading the
/// fields we understand keeps unknown fields and new message types from breaking sessions.
public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: Accessors

    public subscript(key: String) -> JSONValue? {
        if case let .object(object) = self {
            object[key]
        } else {
            nil
        }
    }

    public subscript(index: Int) -> JSONValue? {
        if case let .array(array) = self, array.indices.contains(index) {
            array[index]
        } else {
            nil
        }
    }

    public var string: String? {
        if case let .string(value) = self {
            value
        } else {
            nil
        }
    }

    public var double: Double? {
        if case let .number(value) = self {
            value
        } else {
            nil
        }
    }

    public var int: Int? {
        double.map { Int($0) }
    }

    public var bool: Bool? {
        if case let .bool(value) = self {
            value
        } else {
            nil
        }
    }

    public var array: [JSONValue]? {
        if case let .array(value) = self {
            value
        } else {
            nil
        }
    }

    public var object: [String: JSONValue]? {
        if case let .object(value) = self {
            value
        } else {
            nil
        }
    }

    // MARK: Parsing & printing

    public init(parsing data: Data) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    public init(parsing text: String) throws {
        try self.init(parsing: Data(text.utf8))
    }

    /// Compact single-line encoding (suitable for JSON Lines).
    public func compactString() -> String {
        encoded(formatting: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// Human-readable multi-line encoding.
    public func prettyString() -> String {
        encoded(formatting: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private func encoded(formatting: JSONEncoder.OutputFormatting) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = formatting
        guard let data = try? encoder.encode(self) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = try .object(container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value):
            if value.rounded() == value, abs(value) < 1e15 {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }

    public init(integerLiteral value: Int) {
        self = .number(Double(value))
    }

    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }

    public init(arrayLiteral elements: JSONValue...) {
        self = .array(elements)
    }

    public init(nilLiteral: ()) {
        self = .null
    }

    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
