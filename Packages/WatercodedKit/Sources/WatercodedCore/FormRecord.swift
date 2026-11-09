import Foundation

/// An MCP server asking the user for structured input (MCP "elicitation"): a short form, or a link
/// to open (e.g. to sign in). Both Claude Code and Codex forward these to Watercoded.
///
/// MCP restricts forms to a flat object of simple fields: text (optionally email, URL or date),
/// numbers, yes/no, and single or multiple choice. Anything else is skipped (and if a required field
/// can't be shown, the form can still be declined).
public struct FormRecord: Hashable, Codable, Sendable {
    public struct Option: Hashable, Codable, Sendable, Identifiable {
        public var value: String
        public var title: String
        public var id: String {
            value
        }

        public init(value: String, title: String) {
            self.value = value
            self.title = title
        }
    }

    public struct Field: Hashable, Codable, Sendable, Identifiable {
        public enum Kind: Hashable, Codable, Sendable {
            /// `format`: `email`, `uri`, `date` or `date-time`, when given.
            case text(format: String?, minLength: Int?, maxLength: Int?)
            case number(integer: Bool, minimum: Double?, maximum: Double?)
            case boolean
            case choice([Option])
            case multipleChoice([Option], minItems: Int?, maxItems: Int?)
        }

        /// The property name the answer is sent under.
        public var key: String
        public var title: String
        public var detail: String?
        public var kind: Kind
        public var isRequired: Bool
        public var defaultValue: JSONValue?
        public var id: String {
            key
        }

        public init(
            key: String,
            title: String,
            detail: String? = nil,
            kind: Kind,
            isRequired: Bool = false,
            defaultValue: JSONValue? = nil
        ) {
            self.key = key
            self.title = title
            self.detail = detail
            self.kind = kind
            self.isRequired = isRequired
            self.defaultValue = defaultValue
        }
    }

    public enum Status: String, Codable, Sendable {
        case pending
        case submitted
        case declined
    }

    public var requestID: String
    /// The MCP server asking.
    public var serverName: String?
    public var message: String
    public var fields: [Field]
    /// Link mode: the user opens this URL (e.g. to sign in) instead of filling in fields.
    public var url: URL?
    public var status: Status
    /// What was sent, for showing the finished card (field title → value as text).
    public var summary: [String: String]?

    public init(
        requestID: String,
        serverName: String?,
        message: String,
        fields: [Field] = [],
        url: URL? = nil,
        status: Status = .pending,
        summary: [String: String]? = nil
    ) {
        self.requestID = requestID
        self.serverName = serverName
        self.message = message
        self.fields = fields
        self.url = url
        self.status = status
        self.summary = summary
    }

    /// Fields from an MCP `requestedSchema`, in `order` when given (Claude sends `property_order`),
    /// otherwise by key. Unsupported property types are left out.
    public static func fields(from schema: JSONValue?, order: [String]? = nil) -> [Field] {
        guard let properties = schema?["properties"]?.object else { return [] }
        let required = Set(schema?["required"]?.array?.compactMap(\.string) ?? [])
        let keys = (order ?? []).filter { properties[$0] != nil }
            + properties.keys.filter { !(order ?? []).contains($0) }.sorted()
        return keys.compactMap { key in
            guard let property = properties[key], let kind = kind(of: property) else { return nil }
            return Field(
                key: key,
                title: property["title"]?.string ?? key,
                detail: property["description"]?.string,
                kind: kind,
                isRequired: required.contains(key),
                defaultValue: property["default"]
            )
        }
    }

    private static func kind(of property: JSONValue) -> Field.Kind? {
        switch property["type"]?.string {
        case "string":
            if let options = options(property) {
                return .choice(options)
            }
            return .text(
                format: property["format"]?.string,
                minLength: property["minLength"]?.int,
                maxLength: property["maxLength"]?.int
            )
        case "number", "integer":
            return .number(
                integer: property["type"]?.string == "integer",
                minimum: property["minimum"]?.double,
                maximum: property["maximum"]?.double
            )
        case "boolean":
            return .boolean
        case "array":
            guard let options = property["items"].flatMap(options) else { return nil }
            return .multipleChoice(options, minItems: property["minItems"]?.int, maxItems: property["maxItems"]?.int)
        default:
            return nil
        }
    }

    /// Choices from `oneOf`/`anyOf` (`{const, title}`), or `enum` with optional `enumNames`.
    private static func options(_ schema: JSONValue) -> [Option]? {
        if let titled = (schema["oneOf"] ?? schema["anyOf"])?.array {
            let options = titled.compactMap { option in
                option["const"]?.string.map { Option(value: $0, title: option["title"]?.string ?? $0) }
            }
            return options.isEmpty ? nil : options
        }
        guard let values = schema["enum"]?.array?.compactMap(\.string), !values.isEmpty else { return nil }
        let names = schema["enumNames"]?.array?.compactMap(\.string) ?? []
        return values.enumerated().map { index, value in
            Option(value: value, title: names.indices.contains(index) ? names[index] : value)
        }
    }
}
