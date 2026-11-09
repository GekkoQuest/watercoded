import AppKit
import Orchestrator
import SwiftUI

/// Stops the app's agent and resumes the session in Terminal with the agent's own CLI.
struct ContinueInTerminalButton: View {
    let controller: CurrentController
    @Environment(WindowModel.self) private var window

    var body: some View {
        Button("Continue in Terminal", systemImage: "apple.terminal") {
            Task {
                do {
                    let script = try await controller.handOffToTerminal()
                    guard let terminal = NSWorkspace.shared
                        .urlForApplication(withBundleIdentifier: "com.apple.Terminal")
                    else { return }
                    _ = try await NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: .init())
                } catch {
                    window.present(error, title: "Couldn't Continue in Terminal")
                }
            }
        }
        .disabled(!controller.canContinueInTerminal)
        .help(controller.isTurnActive
            ? "Wait for the agent to finish, or stop it, first"
            : "Stop the agent here and resume this session with its CLI in Terminal")
    }
}
