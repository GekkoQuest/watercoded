import Foundation

/// The state of the pull request a Current opened, as last checked on the host.
public struct PullRequestStatus: Hashable, Codable, Sendable {
    public enum State: String, Codable, Sendable {
        case open
        case merged
        case closed
    }

    public enum Checks: String, Codable, Sendable {
        case none
        case pending
        case passing
        case failing
    }

    public var url: URL
    public var number: Int?
    public var state: State
    public var checks: Checks
    /// Names of failing checks.
    public var failingChecks: [String]
    /// The host's review decision, e.g. `APPROVED` or `CHANGES_REQUESTED`.
    public var reviewDecision: String?
    /// Conversation comments plus reviews with a written body.
    public var commentCount: Int
    public var checkedAt: Date?

    public init(
        url: URL,
        number: Int? = nil,
        state: State = .open,
        checks: Checks = .none,
        failingChecks: [String] = [],
        reviewDecision: String? = nil,
        commentCount: Int = 0,
        checkedAt: Date? = nil
    ) {
        self.url = url
        self.number = number
        self.state = state
        self.checks = checks
        self.failingChecks = failingChecks
        self.reviewDecision = reviewDecision
        self.commentCount = commentCount
        self.checkedAt = checkedAt
    }

    public var changesRequested: Bool {
        reviewDecision == "CHANGES_REQUESTED"
    }

    /// "#12" or "the pull request".
    public var name: String {
        number.map { "#\($0)" } ?? "the pull request"
    }
}
