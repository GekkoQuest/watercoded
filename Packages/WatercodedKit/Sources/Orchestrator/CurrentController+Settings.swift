import AgentKit
import Foundation
import WatercodedCore

extension CurrentController {
    // MARK: Settings

    /// Changes permissions. Applied live when the provider supports it, otherwise on the next message.
    public func setPermissionMode(_ mode: PermissionMode) async {
        guard mode != current.permissionMode else { return }
        update { $0.permissionMode = mode }
        await applyLive { try await $0.setPermissionMode(mode) }
        scheduleSave()
    }

    /// Changes the model (`nil` = provider default). Applied live when possible.
    public func setModel(_ model: String?) async {
        guard model != current.model else { return }
        update { $0.model = model }
        await applyLive { try await $0.setModel(model) }
        scheduleSave()
    }

    /// Changes reasoning effort. Takes effect from the next message (the agent restarts).
    public func setEffort(_ effort: String?) async {
        guard effort != current.effort else { return }
        update { $0.effort = effort }
        update { $0.restartSessionWhenIdle = true }
        if !isTurnActive {
            await stopSession()
        }
        scheduleSave()
    }

    /// Runs a live settings change; if the provider can't, restarts so the next message picks it up.
    private func applyLive(_ change: (any AgentSession) async throws -> Void) async {
        guard let session else { return }
        if capabilities.contains(.liveSettings) {
            do {
                try await change(session)
                return
            } catch {
                // Fall back to a restart below.
            }
        }
        await stopSession()
    }
}
