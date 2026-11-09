import Foundation
import ProcessKit

/// Shipping a Current's work: commit, then merge locally or push and open a pull request.
extension GitClient {
    /// Files in the working tree (tracked and untracked, honoring `.gitignore`), relative paths.
    public func listFiles(in worktree: URL) async throws -> [String] {
        let output = try await run(
            ["ls-files", "--cached", "--others", "--exclude-standard", "-z"],
            in: worktree,
            trim: false
        )
        return output.split(separator: "\0").map(String.init)
    }

    /// `git diff --stat` of the working tree against `base`.
    public func diffStat(in worktree: URL, against base: String) async throws -> String {
        try await run(["diff", "--stat", base], in: worktree)
    }

    public func hasUncommittedChanges(in worktree: URL) async throws -> Bool {
        try await !run(["status", "--porcelain"], in: worktree).isEmpty
    }

    /// Commits everything in the working tree as the user, running their hooks.
    @discardableResult
    public func commitEverything(in worktree: URL, message: String) async throws -> String {
        let email = try? await run(["config", "user.email"], in: worktree)
        guard let email, !email.isEmpty else { throw GitError.identityMissing }
        try await run(["add", "--all"], in: worktree)
        try await run(["commit", "--quiet", "--message", message], in: worktree)
        return try await headCommit(in: worktree)
    }

    /// Number of commits on `head` that `base` doesn't have.
    public func commitsAhead(of base: String, head: String, in repository: URL) async throws -> Int {
        try await Int(run(["rev-list", "--count", "\(base)..\(head)"], in: repository)) ?? 0
    }

    /// Merges `branch` into `target`, which must be checked out and clean in `repository`.
    /// A conflicting merge is aborted, leaving everything as it was.
    public func merge(_ branch: String, into target: String, in repository: URL) async throws {
        let current = try await currentBranch(in: repository) ?? "HEAD"
        guard current == target else { throw GitError.wrongBranch(expected: target, actual: current) }
        guard try await !hasUncommittedChanges(in: repository) else {
            throw GitError.uncommittedChanges(path: repository.path)
        }
        do {
            try await run(["merge", "--no-ff", "--no-edit", branch], in: repository)
        } catch {
            _ = try? await run(["merge", "--abort"], in: repository)
            throw GitError.mergeConflict(branch: branch)
        }
    }

    /// The remote to publish to: `origin` when it exists, else the first one.
    public func defaultRemote(in repository: URL) async throws -> String? {
        let remotes = try await run(["remote"], in: repository).split(separator: "\n").map(String.init)
        return remotes.contains("origin") ? "origin" : remotes.first
    }

    public func remoteURL(_ remote: String, in repository: URL) async throws -> String {
        try await run(["remote", "get-url", remote], in: repository)
    }

    public func push(_ branch: String, to remote: String, in worktree: URL) async throws {
        try await run(["push", "--set-upstream", remote, branch], in: worktree)
    }

    /// Opens a pull request with the GitHub CLI (`gh`) when it's installed and signed in.
    /// Returns its URL, or `nil` when `gh` isn't available (callers fall back to ``compareURL``).
    public func createPullRequest(
        in worktree: URL,
        base: String,
        head: String,
        title: String,
        body: String
    ) async throws -> URL? {
        guard let gh = await environment.locate("gh") else { return nil }
        let result = try await ProcessRunner.run(
            executable: gh,
            arguments: ["pr", "create", "--base", base, "--head", head, "--title", title, "--body", body],
            currentDirectory: worktree,
            environment: environment.environment(),
            timeout: .seconds(60)
        )
        guard result.succeeded else {
            // Not signed in, or not a GitHub remote: let the caller open the compare page instead.
            return nil
        }
        return result.standardOutput.split(separator: "\n").last.flatMap { URL(string: String($0)) }
    }

    /// The web page for opening a pull/merge request from `head` into `base`, for GitHub,
    /// GitLab and Bitbucket remotes (SSH or HTTPS).
    public static func compareURL(remote: String, base: String, head: String) -> URL? {
        var path = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasSuffix(".git") {
            path.removeLast(4)
        }
        let host: String
        let repository: String
        if path.hasPrefix("git@"), let colon = path.firstIndex(of: ":") {
            host = String(path[path.index(path.startIndex, offsetBy: 4) ..< colon])
            repository = String(path[path.index(after: colon)...])
        } else if let url = URL(string: path), let urlHost = url.host() {
            host = urlHost
            repository = String(url.path().drop { $0 == "/" })
        } else {
            return nil
        }
        let encodedHead = head.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? head
        let encodedBase = base.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? base
        let page = if host.contains("gitlab") {
            // GitLab's parameter names contain brackets, which must be percent-encoded in a URL.
            "https://\(host)/\(repository)/-/merge_requests/new?merge_request%5Bsource_branch%5D=\(encodedHead)"
                + "&merge_request%5Btarget_branch%5D=\(encodedBase)"
        } else if host.contains("bitbucket") {
            "https://\(host)/\(repository)/pull-requests/new?source=\(encodedHead)&dest=\(encodedBase)"
        } else {
            "https://\(host)/\(repository)/compare/\(encodedBase)...\(encodedHead)?expand=1"
        }
        return URL(string: page)
    }
}
