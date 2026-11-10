import Orchestrator
import SwiftUI

/// "Branch from Here" and "Edit and Resend" for a message that started a turn. Each opens a new
/// session in its own worktree; the original session is left as it was.
struct BranchMenuItems: View {
    let controller: CurrentController
    let messageID: UUID
    @Environment(Workspace.self) private var workspace
    @Environment(WindowModel.self) private var window

    var body: some View {
        Button("Branch from Here", systemImage: "arrow.triangle.branch") { branch(.after) }
            .disabled(!workspace.canBranch(controller, at: messageID, .after))
            .help(workspace
                .branchingUnavailableReason(controller, at: messageID, .after) ?? "Start a new session from this turn")
        Button("Edit and Resend…", systemImage: "pencil") { branch(.before) }
            .disabled(!workspace.canBranch(controller, at: messageID, .before))
            .help(workspace
                .branchingUnavailableReason(controller, at: messageID, .before) ?? "Edit this turn in a new session")
    }

    private func branch(_ point: BranchPoint) {
        Task {
            do {
                let copy = try await workspace.branch(controller, at: messageID, point)
                window.selection = copy.id
            } catch {
                window.present(error, title: "Couldn't Branch")
            }
        }
    }
}
