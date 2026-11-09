import AgentKit
import Foundation
import WatercodedCore

extension CurrentController {
    /// Runs the repository's worktree setup, shown in the transcript like a command the agent ran.
    func runSetup(_ setup: @Sendable () async -> WorktreePreparer.Outcome) async {
        let callID = "watercoded-setup-\(id)"
        handle(.toolCallStarted(ToolCall(
            callID: callID,
            name: "Worktree setup",
            kind: .shell,
            summary: "Preparing the worktree (repository settings)",
            input: [:]
        )))
        let outcome = await setup()
        handle(.toolCallFinished(callID: callID, output: outcome.log, isError: outcome.failed))
        if outcome.failed {
            append(.notice(Notice(.warning, "Worktree setup had problems. The agent is starting anyway.")))
        }
    }
}
