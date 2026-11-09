import AgentKit
import Foundation
import GitKit
import WatercodedCore

/// Where landed work goes.
public enum LandDestination: Hashable, Sendable {
    /// Merge the Current's branch into `branch` in the repository's own checkout.
    case merge(into: String)
    /// Push the branch and open a pull request against `base`.
    case pullRequest(base: String)
    /// Only commit; leave the branch for later.
    case commitOnly
}

public struct LandOptions: Hashable, Sendable {
    public var commitMessage: String
    public var destination: LandDestination
    /// Remove the worktree checkout afterwards (the branch is kept).
    public var removeWorktree: Bool

    public init(commitMessage: String, destination: LandDestination, removeWorktree: Bool) {
        self.commitMessage = commitMessage
        self.destination = destination
        self.removeWorktree = removeWorktree
    }
}

public struct LandResult: Hashable, Sendable {
    public var commit: String?
    public var merged = false
    public var pullRequestURL: URL?
    /// Where to open a pull request in the browser when it couldn't be created automatically.
    public var compareURL: URL?
}

extension Workspace {
    /// The branch the Current's work would merge into (the repository's checked-out branch).
    public func landingTarget(for id: CurrentID) async -> String? {
        guard let controller = controller(id), let pool = pool(controller.current.poolID) else { return nil }
        return try? await git.currentBranch(in: pool.rootURL)
    }

    /// A suggested commit message: on-device when available, otherwise from the title.
    public func draftCommitMessage(for id: CurrentID) async -> String {
        guard let controller = controller(id) else { return "" }
        let current = controller.current
        let prompt = controller.transcript.compactMap {
            if case let .user(text) = $0.content {
                text
            } else {
                nil
            }
        }
        .first
        if let summarizer, let prompt,
           let stat = try? await git.diffStat(in: current.channel.url, against: current.channel.baseCommit),
           let message = await summarizer.commitMessage(forPrompt: prompt, diffStat: stat) {
            return message
        }
        return current.title
    }

    /// Commits the Current's work and ships it according to `options`, then settles the Current.
    public func land(_ id: CurrentID, options: LandOptions) async throws -> LandResult {
        guard let controller = controller(id), let pool = pool(controller.current.poolID) else {
            throw WorkspaceError.poolNotFound
        }
        let channel = controller.current.channel
        var result = LandResult()

        if try await git.hasUncommittedChanges(in: channel.url) {
            let message = options.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            result.commit = try await git.commitEverything(
                in: channel.url,
                message: message.isEmpty ? controller.current.title : message
            )
        }
        guard try await git.commitsAhead(of: channel.baseCommit, head: "HEAD", in: channel.url) > 0 else {
            throw GitError.nothingToLand
        }

        switch options.destination {
        case let .merge(target) where channel.kind == .worktree:
            try await git.merge(channel.branch, into: target, in: pool.rootURL)
            result.merged = true
        case .merge, .commitOnly:
            break
        case let .pullRequest(base):
            guard let remote = try await git.defaultRemote(in: pool.rootURL) else {
                throw GitError.commandFailed(arguments: ["push"], message: "this repository has no remote to push to")
            }
            try await git.push(channel.branch, to: remote, in: channel.url)
            var body = await markdown(for: id, includeTranscript: false)
            if let issue = controller.current.issue {
                body += "\n\nCloses #\(issue.number)"
            }
            result.pullRequestURL = try await git.createPullRequest(
                in: channel.url, base: base, head: channel.branch, title: controller.current.title, body: body
            )
            if result.pullRequestURL == nil, let remoteURL = try? await git.remoteURL(remote, in: pool.rootURL) {
                result.compareURL = GitClient.compareURL(remote: remoteURL, base: base, head: channel.branch)
            }
        }

        if let url = result.pullRequestURL {
            controller.update { $0.pullRequest = PullRequestStatus(url: url, number: Int(url.lastPathComponent)) }
        }
        await controller.settle()
        if options.removeWorktree, channel.kind == .worktree {
            try await worktrees.removeChannel(channel, from: pool)
        }
        return result
    }
}
