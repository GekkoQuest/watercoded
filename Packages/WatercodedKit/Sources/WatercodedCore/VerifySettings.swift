import Foundation

/// A repository's own check (tests, build, lint) that Watercoded runs itself, so the water reflects
/// whether the work actually passes rather than what the agent says it did.
public struct VerifySettings: Hashable, Codable, Sendable {
    /// Shell command run in the session's folder, e.g. `npm test`.
    public var command: String
    /// Run after every turn in which the agent edited files.
    public var runsAfterEdits: Bool

    public init(command: String, runsAfterEdits: Bool = true) {
        self.command = command
        self.runsAfterEdits = runsAfterEdits
    }
}
