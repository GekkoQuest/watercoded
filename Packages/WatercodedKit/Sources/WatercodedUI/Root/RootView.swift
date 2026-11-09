import AgentKit
import GitKit
import Meniscus
import Orchestrator
import SwiftUI
import UniformTypeIdentifiers
import WatercodedCore
import WatercodedDesign

/// The main window: sidebar of Pools and Currents, the selected Current, and its inspector.
public struct RootView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(WaterEngine.self) private var engine
    @Environment(AppSettings.self) private var settings
    @Environment(ProviderStatus.self) private var providers
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var window = WindowModel()

    public init() {}

    public var body: some View {
        @Bindable var window = window
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 400)
        } detail: {
            // Attached to the detail rather than the split view, the inspector sits below the toolbar
            // instead of running full height behind it, so the toolbar reads as one surface.
            detail
                .inspector(isPresented: $window.isInspectorPresented) {
                    if let controller = selectedController {
                        CurrentInspector(controller: controller)
                            .inspectorColumnWidth(min: 300, ideal: 420, max: 720)
                    }
                }
        }
        .background { waterInfrastructure }
        .overlay(alignment: .top) { settlePrompt }
        .sheet(item: Binding(
            get: { window.landing.flatMap(workspace.controller) },
            set: {
                if $0 == nil {
                    window.landing = nil
                }
            }
        )) { controller in
            LandSheet(controller: controller)
        }
        .sheet(item: Binding(
            get: { window.importingInto.map { ImportTarget(id: $0) } },
            set: {
                if $0 == nil {
                    window.importingInto = nil
                }
            }
        )) { target in
            ImportSessionsSheet(poolID: target.id) { window.selection = $0 }
        }
        .sheet(isPresented: $window.isNewCurrentPresented) {
            NewCurrentSheet(initialPool: window.newCurrentPool) { window.selection = $0 }
        }
        .fileImporter(isPresented: $window.isAddingPool, allowedContentTypes: [.folder]) { result in
            Task { await addPool(result) }
        }
        .alert(item: $window.presentedError) { error in
            Alert(title: Text(error.title), message: Text(error.message))
        }
        .confirmationDialog(
            "“\(window.folderAwaitingInitialization?.lastPathComponent ?? "")” isn't a git repository",
            isPresented: Binding(
                get: { window.folderAwaitingInitialization != nil },
                set: {
                    if !$0 {
                        window.folderAwaitingInitialization = nil
                    }
                }
            ),
            presenting: window.folderAwaitingInitialization
        ) { folder in
            Button("Initialize Repository") { Task { await initializeRepository(at: folder) } }
            Button("Choose Another Folder…") { window.isAddingPool = true }
        } message: { _ in
            Text("Watercoded can run `git init` here. Nothing is staged or committed, "
                + "and agents work in this folder until you make a first commit.")
        }
        .environment(window)
        .focusedSceneValue(\.windowModel, window)
        .task {
            AttentionNotifier.shared.install(workspace: workspace, settings: settings) { [window] id in
                window.selection = id
            }
            await workspace.load()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            AttentionNotifier.shared.appDidBecomeActive()
        }
        .onChange(of: dockBadge, initial: true) { _, badge in NSApp.dockTile.badgeLabel = badge }
        .onChange(of: reduceMotion, initial: true) { _, value in engine.reduceMotion = value }
        .onChange(of: settings.physicsIntensity, initial: true) { _, value in engine.intensity = value }
        .onChange(of: settings.hapticsEnabled, initial: true) { _, value in engine.hapticsEnabled = value }
        .onChange(of: settings.keepAgentsRunning, initial: true) { _, value in
            workspace.backgroundSessionsEnabled = value
        }
        .onChange(of: window.selection, initial: true) { _, id in engine.hapticVesselKey = id.map(AnyHashable.init) }
        .onAppear { engine.onShake = { [window] level in Self.handleShake(level, window: window, settings: settings) } }
        .frame(minWidth: 860, minHeight: 560)
    }

    @ViewBuilder private var detail: some View {
        if let controller = selectedController {
            CurrentScreen(controller: controller)
                .id(controller.id)
        } else if workspace.isLoaded, workspace.pools.isEmpty {
            WelcomeView()
        } else {
            ContentUnavailableView {
                Label("No Session Selected", systemImage: "bubble.left.and.text.bubble.right")
            } description: {
                Text("Pick a session in the sidebar, or start a new one.")
            } actions: {
                Button("New Session") { window.beginNewCurrent() }
                    .keyboardShortcut("n")
                    .disabled(workspace.pools.isEmpty)
                Button("Try the Demo") { Task { await startDemo() } }
            }
        }
    }

    /// The display link plus one invisible water sync per Current.
    private var waterInfrastructure: some View {
        ZStack {
            WaterFrameDriver(engine: engine)
            ForEach(workspace.currents) { CurrentWaterSync(controller: $0) }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var settlePrompt: some View {
        if window.isSettlePromptVisible, let controller = selectedController {
            SettlePrompt(controller: controller) { window.isSettlePromptVisible = false }
                .padding(.top, Spacing.medium)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// Number of Currents blocked on the user, shown on the Dock icon.
    private var dockBadge: String? {
        let count = workspace.shore.count
        return settings.dockBadgeEnabled && count > 0 ? "\(count)" : nil
    }

    private var selectedController: CurrentController? {
        window.selection.flatMap(workspace.controller)
    }

    private func addPool(_ result: Result<URL, any Error>) async {
        do {
            let url = try result.get()
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let pool = try await workspace.addPool(at: url)
            window.beginNewCurrent(in: pool.id)
        } catch GitError.notARepository {
            if let url = try? result.get() {
                window.folderAwaitingInitialization = url
            }
        } catch {
            window.present(error, title: "Couldn't Add Repository")
        }
    }

    private func startDemo() async {
        do {
            window.selection = try await workspace.startDemo().id
        } catch {
            window.present(error, title: "Couldn't Start the Demo")
        }
    }

    private func initializeRepository(at folder: URL) async {
        do {
            let pool = try await workspace.initializeRepositoryAndAddPool(at: folder)
            window.beginNewCurrent(in: pool.id)
        } catch {
            window.present(error, title: "Couldn't Initialize Repository")
        }
    }

    private struct ImportTarget: Identifiable {
        let id: PoolID
    }

    private static func handleShake(_ level: ShakeLevel, window: WindowModel, settings: AppSettings) {
        guard settings.shakeToSettle, level >= .vigorous, window.selection != nil else { return }
        withAnimation(Motion.standard) { window.isSettlePromptVisible = true }
    }
}
