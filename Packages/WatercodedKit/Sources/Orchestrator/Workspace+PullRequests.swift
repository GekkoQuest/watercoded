import Foundation
import GitKit
import WatercodedCore

extension Workspace {
    /// How often open pull requests are checked.
    static let pullRequestPollInterval: Duration = .seconds(120)

    /// Checks open pull requests now and then every couple of minutes, until shutdown.
    func startWatchingPullRequests() {
        pullRequestWatch?.cancel()
        pullRequestWatch = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshPullRequests()
                try? await Task.sleep(for: Self.pullRequestPollInterval)
            }
        }
    }

    /// Fetches the latest state of every open pull request and raises attention for what changed.
    public func refreshPullRequests() async {
        for controller in currents {
            guard let old = controller.current.pullRequest, old.state == .open,
                  let pool = pool(controller.current.poolID),
                  let new = await git.pullRequestStatus(old.url, in: pool.rootURL) else { continue }
            controller.update { $0.pullRequest = new }
            controller.scheduleSave()
            for change in Self.changes(from: old, to: new) {
                onAttention?(controller, .pullRequestChanged(change))
            }
        }
    }

    static func changes(from old: PullRequestStatus, to new: PullRequestStatus) -> [PullRequestChange] {
        var changes: [PullRequestChange] = []
        if new.state == .merged, old.state != .merged {
            return [.merged]
        }
        if new.state == .closed, old.state != .closed {
            return [.closed]
        }
        if new.checks == .failing, old.checks != .failing || new.failingChecks != old.failingChecks {
            changes.append(.checksFailed(new.failingChecks))
        } else if new.checks == .passing, old.checks != .passing {
            changes.append(.checksPassed)
        }
        if new.changesRequested, !old.changesRequested {
            changes.append(.changesRequested)
        } else if new.commentCount > old.commentCount {
            changes.append(.newComments(new.commentCount - old.commentCount))
        }
        return changes
    }
}
