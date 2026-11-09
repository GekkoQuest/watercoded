import AgentKit
import ClaudeCodeProvider
import CodexProvider
import Foundation
import Meniscus
import OnDeviceIntelligence
import Orchestrator
import ProcessKit
import ReplayProvider
import WatercodedUI

/// The composition root: the only place that knows about concrete providers and storage.
///
/// To add a provider: create a module that implements `AgentProvider`, depend on it from the
/// app target, and list it here. Nothing else changes.
@MainActor
struct AppEnvironment {
    let workspace: Workspace
    let providerStatus: ProviderStatus
    let waterEngine: WaterEngine
    let settings: AppSettings

    static func live() -> AppEnvironment {
        let registry = ProviderRegistry([
            // Background sessions run under this same binary in `--relay` mode.
            ClaudeCodeProvider(relay: Bundle.main.executableURL.map { RelayCommand(executable: $0) }),
            CodexProvider(),
            ReplayProvider()
        ])
        let workspace = Workspace(registry: registry, repository: FileWorkspaceRepository())
        // Titles and summaries come from Apple's on-device model when Apple Intelligence is available.
        workspace.summarizer = OnDeviceSummarizer()
        return AppEnvironment(
            workspace: workspace,
            providerStatus: ProviderStatus(registry: registry),
            waterEngine: WaterEngine(),
            settings: AppSettings()
        )
    }
}
