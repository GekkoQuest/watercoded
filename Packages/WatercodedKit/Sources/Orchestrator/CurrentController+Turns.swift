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
    func migrateBranchCheckpointsIfNeeded() {
        // Older app versions kept checkpoints after compaction. Migrate those saved turns too.
        if !capabilities.contains(.branchingAcrossCompaction),
           current.turnSnapshots?.allSatisfy({ $0.checkpointInvalidatedByCompaction == nil }) == true,
           let boundary = transcript.last(where: {
               if case let .notice(notice) = $0.content {
                   return notice.text.hasPrefix("Context compacted")
               }
               return false
           })?.date {
            invalidateBranchCheckpoints(before: boundary)
        }
    }

    /// File snapshots remain usable for review, even when a provider discards old conversation history.
    func invalidateBranchCheckpoints(before date: Date? = nil) {
        update {
            guard var snapshots = $0.turnSnapshots else { return }
            for index in snapshots.indices where snapshots[index].afterCommit != nil
                && date.map({ snapshots[index].startedAt <= $0 }) != false {
                snapshots[index].checkpoint = nil
                snapshots[index].checkpointInvalidatedByCompaction = true
            }
            $0.turnSnapshots = snapshots
        }
        scheduleSave()
    }

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
    func recordTurnEnd(
        _ outcome: TurnOutcome,
        snapshot: TurnSnapshot?,
        checkpoint: String?,
        generation: Int
    ) async -> Bool? {
        var changed: Bool?
        if let snapshot, snapshot.afterCommit == nil {
            let ref = "refs/watercoded/\(id)/turn-\(snapshot.index)-after"
            let commit = await snapshotter?(current.channel.url, ref, "After turn \(snapshot.index)")
            if commit != nil {
                activity.fileChangeRevision += 1
            }
            update {
                guard let index = $0.turnSnapshots?.firstIndex(where: { $0.index == snapshot.index }) else { return }
                $0.turnSnapshots?[index].afterCommit = commit
                // Compaction may have invalidated this turn while its snapshot was being written.
                if checkpointGeneration != generation {
                    $0.turnSnapshots?[index].checkpoint = nil
                    $0.turnSnapshots?[index].checkpointInvalidatedByCompaction = true
                } else if $0.turnSnapshots?[index].checkpointInvalidatedByCompaction != true {
                    $0.turnSnapshots?[index].checkpoint = checkpoint
                }
            }
            changed = await snapshotChanges?(current.channel.url, snapshot.beforeCommit, commit)
        }
        if case .completed = outcome {
            await summarize()
        }
        scheduleSave()
        return changed
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
