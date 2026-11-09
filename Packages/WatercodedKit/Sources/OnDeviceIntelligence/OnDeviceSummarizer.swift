import Foundation
import FoundationModels
import Orchestrator

/// Writes Current titles and summaries with Apple's on-device model (Foundation Models).
///
/// Free, private and offline: nothing leaves the Mac and no agent tokens are spent. When Apple
/// Intelligence is unavailable (turned off, unsupported hardware, model still downloading)
/// every method returns `nil` and Watercoded keeps the prompt-based title.
public struct OnDeviceSummarizer: CurrentSummarizer {
    public init() {}

    public var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability {
            true
        } else {
            false
        }
    }

    public func title(forPrompt prompt: String, reply: String) async -> String? {
        await generate(
            instructions: """
            You name coding tasks for a sidebar. Reply with a title of 2 to 6 words in sentence case. \
            No quotes, no trailing punctuation, no emoji.
            """,
            input: "Task: \(prompt.prefix(1500))\n\nAgent's reply: \(reply.prefix(1500))",
            maxLength: 60
        )
    }

    public func summary(forPrompt prompt: String, reply: String) async -> String? {
        await generate(
            instructions: """
            You summarize where a coding task stands, for a list row. Reply with one plain sentence \
            of at most 14 words, present tense, describing what the agent did or found. No quotes.
            """,
            input: "Task: \(prompt.prefix(1000))\n\nAgent's latest reply: \(reply.prefix(2500))",
            maxLength: 120
        )
    }

    public func commitMessage(forPrompt prompt: String, diffStat: String) async -> String? {
        await generate(
            instructions: "You write git commit messages. Reply with one subject line in the imperative mood, "
                + "at most 60 characters, no trailing period, no quotes, describing the change.",
            input: "What was asked: \(prompt.prefix(1200))\n\nFiles changed:\n\(diffStat.prefix(1500))",
            maxLength: 72
        )
    }

    private func generate(instructions: String, input: String, maxLength: Int) async -> String? {
        guard isAvailable else { return nil }
        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: input)
            return Self.clean(response.content, maxLength: maxLength)
        } catch {
            return nil // guardrails, context size, model busy: keep the existing text
        }
    }

    /// Strips quotes and stray formatting the model sometimes adds; rejects empty or rambling output.
    static func clean(_ text: String, maxLength: Int) -> String? {
        var line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’*#`"))
            .trimmingCharacters(in: .whitespaces)
        if line.lowercased().hasPrefix("title:") {
            line = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        }
        guard !line.isEmpty, line.count <= maxLength else { return nil }
        return line
    }
}
