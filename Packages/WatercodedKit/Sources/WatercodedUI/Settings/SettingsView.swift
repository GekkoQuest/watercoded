import AgentKit
import GitKit
import Meniscus
import Orchestrator
import SwiftUI
import WatercodedCore
import WatercodedDesign

/// The Settings window (⌘,).
public struct SettingsView: View {
    public init() {}

    public var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Appearance", systemImage: "paintbrush") { WaterSettings() }
            Tab("Agents", systemImage: "sparkles") { AgentSettings() }
            Tab("Storage", systemImage: "externaldrive") { StorageSettings() }
        }
        .frame(width: 560, height: 420)
    }
}

private struct GeneralSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Picker("Default permissions", selection: $settings.defaultPermissionMode) {
                ForEach(PermissionMode.allCases) { Text($0.displayName).tag($0) }
            }
            Toggle("Run new sessions in their own worktree", isOn: $settings.isolateByDefault)
            Toggle("Notify me when an agent needs me or finishes", isOn: $settings.notificationsEnabled)
            Toggle("Show a badge on the Dock icon", isOn: $settings.dockBadgeEnabled)
            Toggle("Keep agents working after Watercoded quits", isOn: $settings.keepAgentsRunning)
                .help("Agents run in the background and Watercoded reconnects when you open it again. "
                    + "Applies to agents started after the change.")
            Toggle("Keep Mac awake while sessions run", isOn: $settings.keepAwakeWhileRunning)
                .help("Prevents automatic sleep until all active turns finish, including pauses for approval. "
                    + "The display can still sleep. Applies while Watercoded is open.")
            LabeledContent("Worktrees", value: WorktreeManager.defaultRoot.path(percentEncoded: false))
            LabeledContent("Data", value: FileWorkspaceRepository.defaultRoot.path(percentEncoded: false))
        }
        .formStyle(.grouped)
    }
}

private struct WaterSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var settings = settings
        Form {
            Picker("Physics", selection: $settings.physicsIntensity) {
                ForEach(PhysicsIntensity.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Trackpad haptics", isOn: $settings.hapticsEnabled)
            Toggle("Shake the window to stop the agent", isOn: $settings.shakeToSettle)
            if reduceMotion {
                Label(
                    "Reduce Motion is on, so the water stays still and levels change without waves.",
                    systemImage: "info.circle"
                )
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AgentSettings: View {
    @Environment(ProviderStatus.self) private var providers

    var body: some View {
        Form {
            Section {
                ForEach(providers.registry.descriptors) { descriptor in
                    ProviderStatusRow(descriptor: descriptor, availability: providers.availability(of: descriptor.id))
                }
            } footer: {
                Text(
                    "Watercoded runs the agent CLIs you've installed and signed in to. It never sees your credentials."
                )
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await providers.refresh() }
        .toolbar {
            Button("Check Again", systemImage: "arrow.clockwise") { Task { await providers.refresh() } }
                .disabled(providers.isRefreshing)
        }
    }
}
