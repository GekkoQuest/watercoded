import AgentKit
import Foundation
import GitKit
import WatercodedCore

extension Workspace {
    /// Starts a scripted Current against a small sample repository, so a new user can see
    /// Watercoded work without installing an agent CLI or spending tokens.
    ///
    /// The sample repository lives at ``demoRoot``. It's created and committed (under a Watercoded
    /// identity, since it's ours) on first use; later demos reuse it.
    public func startDemo() async throws -> CurrentController {
        guard let providerID = registry.descriptors.first(where: \.isDemo)?.id else {
            throw AgentError.unsupported("The demo")
        }
        let pool = try await demoPool()
        return try await startCurrent(NewCurrentRequest(
            poolID: pool.id,
            prompt: "Fix the race in TokenStore: two requests can refresh the token at the same time.",
            title: "Demo: fix the token refresh race",
            providerID: providerID,
            permissionMode: .ask,
            isolation: .worktree
        ))
    }

    private func demoPool() async throws -> Pool {
        let root = demoRoot.standardizedFileURL
        if let existing = pools.first(where: { URL(filePath: $0.rootPath).standardizedFileURL.path == root.path }) {
            return existing
        }
        if try await git.headCommitIfAny(in: root, creatingIfMissing: true) == nil {
            try DemoRepository.writeFiles(to: root)
            try await git.commitAll(
                in: root,
                message: "Sample project for the Watercoded demo",
                identity: (name: "Watercoded", email: "demo@watercoded.invalid")
            )
        }
        var pool = try await addPool(at: root)
        if pool.name != DemoRepository.poolName {
            pool = renamePool(pool.id, to: DemoRepository.poolName) ?? pool
        }
        return pool
    }
}

extension GitClient {
    /// Like ``headCommitIfAny(in:)``, but first creates `url` and runs `git init` there when it
    /// isn't a repository yet.
    fileprivate func headCommitIfAny(in url: URL, creatingIfMissing: Bool) async throws -> String? {
        if !FileManager.default.fileExists(atPath: url.appending(path: ".git").path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try await initializeRepository(at: url)
        }
        return try await headCommitIfAny(in: url)
    }
}

/// Contents of the demo repository.
enum DemoRepository {
    static let poolName = "Watercoded Demo"

    static func writeFiles(to root: URL) throws {
        let files: [String: String] = [
            "README.md": """
            # Watercoded demo

            A tiny sample project used by the **Try the Demo** button. The demo agent is scripted:
            it doesn't edit these files or spend any tokens.
            """,
            "Sources/TokenStore.swift": """
            import Foundation

            /// Holds the current access token and refreshes it when it expires.
            final class TokenStore {
                private var token: String?
                private var expiresAt = Date.distantPast

                func validToken() async throws -> String {
                    if let token, expiresAt > .now { return token }
                    // Two callers can reach this line at once and both refresh.
                    let (fresh, expiry) = try await refresh()
                    token = fresh
                    expiresAt = expiry
                    return fresh
                }

                private func refresh() async throws -> (String, Date) {
                    try await Task.sleep(for: .milliseconds(200))
                    return (UUID().uuidString, .now.addingTimeInterval(3600))
                }
            }
            """
        ]
        for (path, contents) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try (contents + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
