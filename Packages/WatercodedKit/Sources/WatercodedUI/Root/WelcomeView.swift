import AgentKit
import Orchestrator
import SwiftUI
import WatercodedDesign

/// First-run state: no repositories yet. Leads with plain words, shows whether an agent is ready,
/// and offers a zero-setup demo.
struct WelcomeView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(ProviderStatus.self) private var providers
    @Environment(WindowModel.self) private var window
    @Environment(\.openWindow) private var openWindow
    @State private var isStartingDemo = false

    var body: some View {
        VStack(spacing: Spacing.xLarge) {
            VStack(spacing: Spacing.small) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                    .accessibilityHidden(true)
                Text("Welcome to Watercoded").font(.largeTitle.weight(.semibold))
                Text("Pick a git repository and start an agent on a task. Each agent works on its own branch, "
                    + "so you can run several at once.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 460)
            }

            VStack(alignment: .leading, spacing: Spacing.medium) {
                ForEach(realProviders) { descriptor in
                    ProviderStatusRow(descriptor: descriptor, availability: providers.availability(of: descriptor.id))
                }
                if hasMissingProvider {
                    Button("Check Again") { Task { await providers.refresh() } }
                        .disabled(providers.isRefreshing)
                }
            }
            .padding(Spacing.large)
            .frame(maxWidth: 460)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))

            HStack(spacing: Spacing.medium) {
                Button("Try the Demo") { Task { await startDemo() } }
                    .buttonStyle(.glass)
                    .disabled(isStartingDemo)
                    .help("Starts a scripted agent on a sample project. No setup, no tokens.")
                Button("Add Repository…") { window.isAddingPool = true }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            .controlSize(.large)

            Button("What does the water mean?") { openWindow(id: GlossaryView.windowID) }
                .buttonStyle(.link)
        }
        .padding(Spacing.xxLarge)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await providers.loadIfNeeded() }
    }

    /// Providers that do real work (the demo is offered separately).
    private var realProviders: [ProviderDescriptor] {
        providers.registry.descriptors.filter { !$0.isDemo }
    }

    private var hasMissingProvider: Bool {
        realProviders.contains { providers.availability(of: $0.id)?.isAvailable == false }
    }

    private func startDemo() async {
        isStartingDemo = true
        defer { isStartingDemo = false }
        do {
            let controller = try await workspace.startDemo()
            window.selection = controller.id
        } catch {
            window.present(error, title: "Couldn't Start the Demo")
        }
    }
}
