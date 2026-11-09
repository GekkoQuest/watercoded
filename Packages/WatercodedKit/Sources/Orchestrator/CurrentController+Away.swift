import Foundation
import WatercodedCore

/// Coming back to a Current: resuming after a quit, "while you were away", and batch reviews.
extension CurrentController {
    /// Continues a Current whose agent was stopped when the app quit.
    public func resumeAfterQuit() async {
        update { $0.interruptedByQuit = nil }
        await send("Continue where you left off.")
    }

    public func markViewed() {
        update { $0.lastViewedAt = .now }
        scheduleSave()
    }

    /// Whether this Current finished work the user hasn't looked at yet.
    public var hasUnseenResults: Bool {
        guard let ended = current.lastTurnEndedAt, !isTurnActive else { return false }
        return ended > (current.lastViewedAt ?? .distantPast)
    }

    // MARK: Review

    public func addReviewComment(_ comment: ReviewComment) {
        reviewComments.append(comment)
    }

    public func removeReviewComment(_ id: ReviewComment.ID) {
        reviewComments.removeAll { $0.id == id }
    }

    /// Sends all review comments as one message, like submitting a code review.
    public func sendReview(summary: String = "") async {
        guard !reviewComments.isEmpty else { return }
        let message = ReviewComment.message(for: reviewComments, summary: summary)
        reviewComments.removeAll()
        await send(message)
    }

    public func reopen() {
        guard current.status == .settled else { return }
        update { $0.status = .ashore }
        scheduleSave()
    }

    public func rename(to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update {
            $0.title = trimmed
            $0.titleSource = .user
        }
        scheduleSave()
    }
}
