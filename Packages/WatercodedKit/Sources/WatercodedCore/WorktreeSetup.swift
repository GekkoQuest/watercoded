import Foundation

/// How a repository's new worktrees are prepared before the agent starts, so it doesn't begin
/// in a checkout with no dependencies or environment files.
public struct WorktreeSetup: Hashable, Codable, Sendable {
    /// Git-ignored files or folders (relative to the repository root) copied from the main checkout,
    /// e.g. `.env` or `node_modules`. Copies are APFS clones: instant, and no extra space until changed.
    public var copyPaths: [String]
    /// Shell commands run in the new worktree (with the login shell's environment), e.g. `npm install`.
    public var script: String?

    public init(copyPaths: [String] = [], script: String? = nil) {
        self.copyPaths = copyPaths
        self.script = script
    }

    public var isEmpty: Bool {
        copyPaths.isEmpty && (script?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
}
