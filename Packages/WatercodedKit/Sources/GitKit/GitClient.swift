import Foundation
import ProcessKit

public enum GitError: Error, LocalizedError, Sendable, Equatable {
    case gitNotFound
    case notARepository(path: String)
    /// The repository exists but has no commits yet (an "unborn" branch).
    case noCommits(path: String)
    case commandFailed(arguments: [String], message: String)
    case identityMissing
    case wrongBranch(expected: String, actual: String)
    case uncommittedChanges(path: String)
    case mergeConflict(branch: String)
    case nothingToLand

    public var errorDescription: String? {
        switch self {
        case .gitNotFound:
            "Git isn't installed. Install the Xcode Command Line Tools with `xcode-select --install`."
        case let .notARepository(path):
            "“\((path as NSString).lastPathComponent)” isn't inside a git repository. "
                + "Choose a repository folder, or initialize this one."
        case let .noCommits(path):
            "“\((path as NSString).lastPathComponent)” has no commits yet, so it can't be branched into a worktree. "
                + "Make a first commit, or turn off “Run in its own worktree”."
        case .identityMissing:
            "Git doesn't know who you are yet. Run `git config --global user.name \"Your Name\"` and "
                + "`git config --global user.email you@example.com`, then try again."
        case let .wrongBranch(expected, actual):
            "Your repository is on “\(actual)”, not “\(expected)”. "
                + "Switch to \(expected) first, or open a pull request instead."
        case let .uncommittedChanges(path):
            "“\((path as NSString).lastPathComponent)” has uncommitted changes. Commit or stash them first."
        case let .mergeConflict(branch):
            "Merging \(branch) would conflict, so nothing was changed. Ask the agent to rebase, or open a pull request."
        case .nothingToLand:
            "There's nothing to land: the branch has no changes."
        case let .commandFailed(arguments, message):
            "git \(arguments.prefix(2).joined(separator: " ")) failed: \(message)"
        }
    }
}

/// A thin, testable wrapper around the `git` CLI.
///
/// Shelling out (rather than linking libgit2) keeps behavior identical to the user's own git,
/// including their config, hooks and credential helpers.
public struct GitClient: Sendable {
    let environment: ShellEnvironment

    public init(environment: ShellEnvironment = .shared) {
        self.environment = environment
    }

    // MARK: Repository

    /// The top-level directory of the repository containing `url`.
    public func topLevel(of url: URL) async throws -> URL {
        do {
            let path = try await run(["rev-parse", "--show-toplevel"], in: url)
            return URL(filePath: path, directoryHint: .isDirectory)
        } catch GitError.commandFailed {
            throw GitError.notARepository(path: url.path)
        }
    }

    /// The well-known hash of git's empty tree. Diffing against it shows every file as added,
    /// which is the right baseline for a repository with no commits.
    public static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    /// The commit `HEAD` points at. Throws ``GitError/noCommits(path:)`` for a brand-new repository.
    public func headCommit(in url: URL) async throws -> String {
        guard let commit = try await headCommitIfAny(in: url) else { throw GitError.noCommits(path: url.path) }
        return commit
    }

    /// The commit `HEAD` points at, or `nil` when the repository has no commits yet.
    public func headCommitIfAny(in url: URL) async throws -> String? {
        let commit = try await run(
            ["rev-parse", "--verify", "--quiet", "HEAD^{commit}"],
            in: url,
            allowedExitCodes: [0, 1]
        )
        return commit.isEmpty ? nil : commit
    }

    /// The checked-out branch name (also for an unborn branch), or `nil` when `HEAD` is detached.
    public func currentBranch(in url: URL) async throws -> String? {
        let name = try await run(["symbolic-ref", "--quiet", "--short", "HEAD"], in: url, allowedExitCodes: [0, 1])
        return name.isEmpty ? nil : name
    }

    public func branchExists(_ branch: String, in url: URL) async throws -> Bool {
        let output = try await run(["branch", "--list", branch], in: url)
        return !output.isEmpty
    }

    /// Runs `git init` in `url` (no commit, nothing staged).
    public func initializeRepository(at url: URL) async throws {
        try await run(["init", "--quiet"], in: url)
    }

    /// Stages everything and commits. When `identity` is given it overrides the user's git identity
    /// (used only for repositories Watercoded creates itself, such as the demo).
    public func commitAll(in url: URL, message: String, identity: (name: String, email: String)? = nil) async throws {
        try await run(["add", "--all"], in: url)
        var arguments: [String] = []
        if let identity {
            arguments += ["-c", "user.name=\(identity.name)", "-c", "user.email=\(identity.email)"]
        }
        try await run(arguments + ["commit", "--quiet", "--no-verify", "--message", message], in: url)
    }

    // MARK: Worktrees

    /// `git worktree add -b <branch> <path> <base>`.
    public func addWorktree(repository: URL, path: URL, branch: String, base: String) async throws {
        try await run(["worktree", "add", "--quiet", "-b", branch, path.path, base], in: repository)
    }

    /// Checks out an existing branch into a new worktree (e.g. to restore one that was removed).
    public func addWorktree(repository: URL, path: URL, existingBranch: String) async throws {
        try await run(["worktree", "prune"], in: repository)
        try await run(["worktree", "add", "--quiet", path.path, existingBranch], in: repository)
    }

    /// Top-level files and folders git ignores (e.g. `.env`, `node_modules/`), candidates for copying into worktrees.
    public func ignoredTopLevelItems(in repository: URL) async throws -> [String] {
        let output = try await run(
            ["ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "--no-empty-directory"],
            in: repository
        )
        return output.split(separator: "\n").map(String.init)
            .map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
            .filter { !$0.contains("/") && $0 != ".DS_Store" }
            .sorted()
    }

    /// The main repository's `.git` directory for any checkout or worktree inside it.
    public func commonGitDirectory(in directory: URL) async throws -> URL {
        let path = try await run(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: directory)
        return URL(filePath: path, directoryHint: .isDirectory)
    }

    public func removeWorktree(repository: URL, path: URL, force: Bool) async throws {
        var arguments = ["worktree", "remove"]
        if force {
            arguments.append("--force")
        }
        arguments.append(path.path)
        try await run(arguments, in: repository)
    }

    // MARK: Diffs

    /// Unified diff of the working tree against `base`, including untracked files.
    public func diff(in worktree: URL, against base: String) async throws -> String {
        var output = try await run(["diff", "--no-color", "--no-ext-diff", "-M", base], in: worktree, trim: false)
        let untracked = try await run(["ls-files", "--others", "--exclude-standard", "-z"], in: worktree, trim: false)
        for path in untracked.split(separator: "\0") where !path.isEmpty {
            // `--no-index` exits 1 when files differ, which is the expected case here.
            let patch = try await run(
                ["diff", "--no-color", "--no-index", "--", "/dev/null", String(path)],
                in: worktree,
                trim: false,
                allowedExitCodes: [0, 1]
            )
            output += patch
        }
        return output
    }

    // MARK: Running

    @discardableResult
    func run(
        _ arguments: [String],
        in directory: URL,
        trim: Bool = true,
        allowedExitCodes: Set<Int32> = [0],
        extraEnvironment: [String: String] = [:]
    ) async throws -> String {
        guard let git = await environment.locate("git") else { throw GitError.gitNotFound }
        var env = await environment.environment()
        env["GIT_TERMINAL_PROMPT"] = "0" // never block on credential prompts
        env["LC_ALL"] = "C"
        env.merge(extraEnvironment) { _, new in new }
        let result = try await ProcessRunner.run(
            executable: git,
            arguments: ["-c", "core.quotepath=off"] + arguments,
            currentDirectory: directory,
            environment: env
        )
        guard allowedExitCodes.contains(result.exitCode) else {
            let message = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError.commandFailed(arguments: arguments, message: message)
        }
        return trim ? result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) : result.standardOutput
    }
}
