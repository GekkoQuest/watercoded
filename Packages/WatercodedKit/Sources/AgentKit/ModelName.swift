/// Turns a model ID an agent reports into a short name for people.
public enum ModelName {
    /// `claude-opus-5-5` → "Opus 5.5", `claude-sonnet-4-5-20250929` → "Sonnet 4.5",
    /// `claude-3-5-haiku-20241022` → "Haiku 3.5", `opus` → "Opus". Other IDs are returned unchanged.
    public static func display(_ id: String) -> String {
        var name = id
        if let bracket = name.firstIndex(of: "[") {
            name = String(name[..<bracket]) // e.g. a "[1m]" context-window suffix
        }
        if !name.isEmpty, name.allSatisfy(\.isLowercase) {
            return name.capitalized // an alias like "opus"
        }
        guard name.hasPrefix("claude-") else { return id }
        let parts = name.dropFirst("claude-".count).split(separator: "-").map(String.init)
        let isDate = { (part: String) in part.count == 8 && part.allSatisfy(\.isNumber) }
        let words = parts.filter { !$0.allSatisfy(\.isNumber) }.map(\.capitalized)
        let numbers = parts.filter { $0.allSatisfy(\.isNumber) && !isDate($0) }
        guard !words.isEmpty else { return id }
        return ([words.joined(separator: " ")] + (numbers.isEmpty ? [] : [numbers.joined(separator: ".")]))
            .joined(separator: " ")
    }
}
