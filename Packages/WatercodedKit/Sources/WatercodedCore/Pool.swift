import Foundation

/// A project: one git repository that Currents run against.
public struct Pool: Identifiable, Hashable, Codable, Sendable {
    public let id: PoolID
    public var name: String
    /// Absolute path of the repository's top-level directory.
    public var rootPath: String
    public var createdAt: Date
    /// Extra folders agents in this pool may read and edit (e.g. a sibling shared library).
    public var additionalDirectories: [String]?
    /// Tool calls agents in this pool may make without asking.
    public var approvalRules: [ApprovalRule]?
    /// How new worktrees are prepared (copied files, setup script).
    public var worktreeSetup: WorktreeSetup?
    /// The repository's check command, run by Watercoded.
    public var verify: VerifySettings?

    public init(id: PoolID = PoolID(), name: String, rootPath: String, createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.createdAt = createdAt
    }

    public var additionalDirectoryURLs: [URL] {
        (additionalDirectories ?? []).map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    public var rootURL: URL {
        URL(filePath: rootPath, directoryHint: .isDirectory)
    }
}
