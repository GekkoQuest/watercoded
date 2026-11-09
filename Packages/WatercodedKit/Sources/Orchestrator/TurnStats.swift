import Foundation

/// Timing and token counts for one turn, measured as the agent works. Not persisted.
public struct TurnStats: Hashable, Sendable {
    public let startedAt: Date
    public internal(set) var endedAt: Date?
    /// Exact output tokens of the responses finished so far, thinking included.
    public internal(set) var outputTokens = 0
    /// Time spent generating those responses (excludes tool runs and waiting on approvals).
    public internal(set) var generationSeconds: Double = 0
    var generatingSince: Date?

    init(startedAt: Date = .now) {
        self.startedAt = startedAt
    }

    /// Output speed while the model was generating. `nil` until a response has finished.
    public var tokensPerSecond: Double? {
        guard outputTokens > 0, generationSeconds > 0.2 else { return nil }
        return Double(outputTokens) / generationSeconds
    }

    public var isActive: Bool {
        endedAt == nil
    }

    mutating func generationStarted(at date: Date = .now) {
        generatingSince = date
    }

    mutating func generationFinished(outputTokens tokens: Int, at date: Date = .now) {
        outputTokens += tokens
        if let since = generatingSince {
            generationSeconds += date.timeIntervalSince(since)
        }
        generatingSince = nil
    }
}
