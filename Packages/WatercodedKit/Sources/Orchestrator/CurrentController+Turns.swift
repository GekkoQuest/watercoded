import AgentKit
import Foundation
import WatercodedCore

/// What the user should hear about, e.g. as a notification when the app isn't in front.
public enum AttentionEvent: Sendable, Hashable {
    case approvalNeeded(PermissionRequest)
    case planReady
    case questionAsked(String)
    case turnFinished(TurnOutcome)
    /// Something changed on the pull request this Current opened.
    case pullRequestChanged(PullRequestChange)
}

/// A change on a watched pull request worth telling the user about.
public enum PullRequestChange: Sendable, Hashable {
    case checksFailed([String])
    case checksPassed
    case changesRequested
    case newComments(Int)
    case merged
    case closed
}

/// Writes short titles and progress summaries for Currents (e.g. with an on-device model).
/// Returning `nil` keeps the current text.
public protocol CurrentSummarizer: Sendable {
    func title(forPrompt prompt: String, reply: String) async -> String?
    func summary(forPrompt prompt: String, reply: String) async -> String?
    /// A commit message for `diffStat` (e.g. `git diff --stat`) given what the user asked for.
    func commitMessage(forPrompt prompt: String, diffStat: String) async -> String?
}

extension CurrentSummarizer {
    public func commitMessage(forPrompt prompt: String, diffStat: String) async -> String? {
        nil
    }
}

extension CurrentController {
    /// Snapshots the working tree before the agent touches it, so this turn's changes can be shown alone.
    func recordTurnStart() async {
        guard let snapshotter else { return }
        let index = (current.turnSnapshots?.count ?? 0) + 1
        let messageID = transcript.last {
            if case .user = $0.content {
                true
            } else {
                false
            }
        }?.id
        let ref = "refs/watercoded/\(id)/turn-\(index)-before"
        guard let commit = await snapshotter(current.channel.url, ref, "Before turn \(index)") else { return }
        update {
            var snapshot = TurnSnapshot(index: index, startedAt: .now, beforeCommit: commit)
            snapshot.userMessageID = messageID
            $0.turnSnapshots = ($0.turnSnapshots ?? []) + [snapshot]
        }
    }

    /// Snapshots the result of the turn and refreshes the title and summary.
    func recordTurnEnd(_ outcome: TurnOutcome) async {
        if let snapshotter, var snapshots = current.turnSnapshots, let last = snapshots.indices.last,
           snapshots[last].afterCommit == nil {
            let ref = "refs/watercoded/\(id)/turn-\(snapshots[last].index)-after"
            if let commit = await snapshotter(current.channel.url, ref, "After turn \(snapshots[last].index)") {
                snapshots[last].afterCommit = commit
                activity.fileChangeRevision += 1
            }
            snapshots[last].checkpoint = lastCheckpoint
            update { $0.turnSnapshots = snapshots }
        }
        if case .completed = outcome {
            await summarize()
        }
        scheduleSave()
    }

    private func summarize() async {
        guard let summarizer,
              let prompt = transcript.last(where: {
                  if case .user = $0.content {
                      true
                  } else {
                      false
                  }
              }),
              case let .user(promptText) = prompt.content,
              let reply = transcript.last(where: {
                  if case .assistant = $0.content {
                      true
                  } else {
                      false
                  }
              }),
              case let .assistant(replyText) = reply.content
        else { return }

        // Only titles that came from the prompt are replaced; a user's own title is kept.
        if current.titleSource == nil || current.titleSource == .prompt,
           let title = await summarizer.title(forPrompt: promptText, reply: replyText) {
            update {
                $0.title = title
                $0.titleSource = .generated
            }
        }
        if let summary = await summarizer.summary(forPrompt: promptText, reply: replyText) {
            update { $0.summary = summary }
        }
    }
}
