import Foundation
import WatercodedCore

extension CurrentController {
    /// Whether the watched pull request has failing checks or review feedback for the agent.
    public var pullRequestNeedsWork: Bool {
        guard let pull = current.pullRequest, pull.state == .open else { return false }
        return pull.checks == .failing || pull.changesRequested || pull.commentCount > 0
    }

    /// Reopens the Current (recreating its worktree if Land removed it) and asks the agent to deal with
    /// failing checks and review feedback on its pull request, then push.
    public func fixPullRequest() async {
        guard let pull = current.pullRequest else { return }
        reopen()
        var asks: [String] = []
        if pull.checks == .failing {
            let names = pull.failingChecks.isEmpty ? "" : " (\(pull.failingChecks.joined(separator: ", ")))"
            asks.append(
                "CI checks are failing\(names). Use `gh pr checks` and `gh run view --log-failed` "
                    + "to see why, and fix them."
            )
        }
        if pull.changesRequested || pull.commentCount > 0 {
            asks.append("Read the review feedback with `gh pr view --comments` and address it.")
        }
        guard !asks.isEmpty else { return }
        await send("""
        Your pull request \(pull.name) (\(pull.url.absoluteString)) needs work.

        \(asks.map { "- \($0)" }.joined(separator: "\n"))

        Commit and push the branch when you're done, then tell me what changed.
        """)
    }
}
