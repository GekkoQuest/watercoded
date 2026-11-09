import Foundation
import GitKit
import WatercodedCore

extension Workspace {
    /// Loads a GitHub issue from a repository's remote, for starting a Current from it.
    public func issue(_ reference: String, in poolID: PoolID) async throws -> GitHubIssue {
        guard let pool = pool(poolID) else { throw WorkspaceError.poolNotFound }
        return try await git.issue(reference, in: pool.rootURL)
    }
}
