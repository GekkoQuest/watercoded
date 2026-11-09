import Foundation
import WatercodedCore

/// A comment on part of the diff, collected and sent with others as one review.
public struct ReviewComment: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var path: String
    /// e.g. "12–18"; empty for whole-file comments.
    public var lines: String
    /// The diff excerpt the comment refers to, if any.
    public var excerpt: String?
    public var text: String

    public init(id: UUID = UUID(), path: String, lines: String, excerpt: String?, text: String) {
        self.id = id
        self.path = path
        self.lines = lines
        self.excerpt = excerpt
        self.text = text
    }

    /// One message containing every comment, grouped by file.
    public static func message(for comments: [ReviewComment], summary: String) -> String {
        var parts = ["Here's my review of your changes. Please address each comment."]
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            parts.append(trimmed)
        }
        for (index, comment) in comments.enumerated() {
            var block = "\(index + 1). `\(comment.path)`" + (comment.lines.isEmpty ? "" : " (lines \(comment.lines))")
            if let excerpt = comment.excerpt, !excerpt.isEmpty {
                block += "\n```diff\n\(excerpt)\n```"
            }
            block += "\n\(comment.text)"
            parts.append(block)
        }
        return parts.joined(separator: "\n\n")
    }
}
