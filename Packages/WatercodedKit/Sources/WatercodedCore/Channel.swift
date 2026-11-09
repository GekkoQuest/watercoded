import Foundation

/// Where a Current does its work: an isolated git worktree, or the Pool's own checkout.
public struct Channel: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// A dedicated `git worktree` on its own branch (the default).
        case worktree
        /// The Pool's main checkout, shared with the user.
        case checkout
    }

    public var kind: Kind
    /// Absolute path the agent runs in.
    public var path: String
    /// Branch checked out in the channel.
    public var branch: String
    /// Commit the channel started from; diffs are computed against it.
    public var baseCommit: String

    public init(kind: Kind, path: String, branch: String, baseCommit: String) {
        self.kind = kind
        self.path = path
        self.branch = branch
        self.baseCommit = baseCommit
    }

    public var url: URL {
        URL(filePath: path, directoryHint: .isDirectory)
    }
}
