import Foundation

enum MarkdownInline {
    static func parse(_ text: String, directory: URL? = nil) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var result = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        detectLinks(in: &result)
        if let directory {
            for run in Array(result.runs)
                where run.link == nil && run.inlinePresentationIntent?.contains(.code) == true {
                let value = String(result[run.range].characters)
                guard !value.contains("\n"), value != ".", value != "..", let url = URL(string: value),
                      case let .file(file) = TranscriptLink.resolve(url, relativeTo: directory),
                      FileManager.default.fileExists(atPath: file.url.path) else { continue }
                var components = URLComponents(url: file.url, resolvingAgainstBaseURL: false)
                components?.fragment = file.line.map { "L\($0)" + (file.column.map { "C\($0)" } ?? "") }
                result[run.range].link = components?.url
            }
        }
        return result
    }

    /// User input stays literal while ordinary URLs and email addresses remain actionable.
    static func plain(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        detectLinks(in: &result)
        return result
    }

    private static func detectLinks(in result: inout AttributedString) {
        let plain = String(result.characters)
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        for match in detector?.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) ?? [] {
            guard let url = match.url, let range = Range(match.range, in: plain),
                  let start = AttributedString.Index(range.lowerBound, within: result),
                  let end = AttributedString.Index(range.upperBound, within: result) else { continue }
            let target = start ..< end
            guard !result[target].runs
                .contains(where: { $0.link != nil || $0.inlinePresentationIntent?.contains(.code) == true })
            else { continue }
            result[target].link = url
        }
    }
}
