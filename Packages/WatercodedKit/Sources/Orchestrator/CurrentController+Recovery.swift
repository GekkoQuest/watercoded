import Foundation
import WatercodedCore

extension CurrentController {
    /// Older versions marked an already completed turn as failed when its idle relay later exited.
    /// Repair only that specific history shape; leave unfinished turns and other errors alone.
    func recoverCompletedSessionAfterAgentExit() {
        guard current.status == .stalled, current.relay == nil,
              let ended = current.lastTurnEndedAt,
              current.turnSnapshots?.last?.afterCommit != nil,
              transcript.count >= 2,
              let last = transcript.last, last.date >= ended,
              case var .notice(notice) = last.content,
              notice.level == .error, notice.text.hasPrefix("The agent stopped unexpectedly: "),
              case .assistant = transcript[transcript.count - 2].content,
              transcript[transcript.count - 2].date <= ended else { return }
        notice.level = .info
        transcript[transcript.count - 1].content = .notice(notice)
        update { $0.status = .ashore }
        scheduleSave()
    }
}
