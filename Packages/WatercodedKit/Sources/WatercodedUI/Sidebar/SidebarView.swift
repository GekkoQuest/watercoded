import AgentKit
import Orchestrator
import SwiftUI
import WatercodedCore
import WatercodedDesign

/// "Needs You" at the top, then each Pool with its Currents. Searching shows matches across all Currents.
struct SidebarView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(WindowModel.self) private var window
    @Environment(\.appUpdate) private var appUpdate
    @State private var pendingDeletion: CurrentController?

    var body: some View {
        @Bindable var window = window
        Group {
            if window.searchQuery.trimmingCharacters(in: .whitespaces).count >= 2 {
                SearchResultsList(query: window.searchQuery)
            } else {
                currentsList
            }
        }
        .onChange(of: window.selection) { _, selection in
            // Keep this outside the list so search results can also reveal a repository.
            if let selection, let controller = workspace.controller(selection) {
                UserDefaults.standard.set(true, forKey: PoolSection.expansionKey(for: controller.current.poolID))
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { SidebarSearchField() }
        .safeAreaInset(edge: .bottom) { footer }
        .confirmationDialog(
            "Delete “\(pendingDeletion?.current.title ?? "")”?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: {
                if !$0 {
                    pendingDeletion = nil
                }
            }),
            presenting: pendingDeletion
        ) { controller in
            Button("Delete and Remove Worktree", role: .destructive) { delete(controller, removingWorktree: true) }
            Button("Delete, Keep Worktree") { delete(controller, removingWorktree: false) }
        } message: { controller in
            Text(controller.current.channel.kind == .worktree
                ? "The branch \(controller.current.channel.branch) and its commits are kept either way."
                : "The transcript is removed. Your checkout isn't touched.")
        }
    }

    private var currentsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.large) {
                if !workspace.shore.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                        Text("Needs You")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, Spacing.small)
                        ForEach(workspace.shore) {
                            SidebarSessionButton(controller: $0, showsPool: true)
                        }
                    }
                }
                ForEach(workspace.pools) { pool in
                    PoolSection(pool: pool, pendingDeletion: $pendingDeletion)
                }
            }
            .padding(Spacing.small)
        }
        .onMoveCommand { direction in
            moveSelection(direction)
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard direction == .up || direction == .down else { return }
        let visible = workspace.shore + workspace.pools.flatMap { pool in
            let expanded = UserDefaults.standard.object(forKey: PoolSection.expansionKey(for: pool.id)) as? Bool ?? true
            return expanded ? Self.nested(workspace.currents(in: pool.id)).map(\.controller) : []
        }
        guard !visible.isEmpty else { return }
        let index = visible.firstIndex { $0.id == window.selection }
        let next = index.map { $0 + (direction == .down ? 1 : -1) } ?? (direction == .down ? 0 : visible.count - 1)
        window.selection = visible[min(max(next, 0), visible.count - 1)].id
    }

    /// A session followed by the sessions it delegated to (and theirs), indented by depth.
    struct NestedRow: Identifiable {
        let controller: CurrentController
        let depth: Int
        var id: CurrentID {
            controller.id
        }
    }

    static func nested(_ currents: [CurrentController]) -> [NestedRow] {
        let ids = Set(currents.map(\.id))
        var rows: [NestedRow] = []
        func add(_ controller: CurrentController, depth: Int) {
            rows.append(NestedRow(controller: controller, depth: depth))
            for child in currents.filter({ $0.current.parentID == controller.id })
                .sorted(by: { $0.current.createdAt < $1.current.createdAt }) {
                add(child, depth: depth + 1)
            }
        }
        // Top level: sessions without a parent here (a parent may have been deleted).
        for controller in currents where controller.current.parentID.map({ !ids.contains($0) }) ?? true {
            add(controller, depth: 0)
        }
        return rows
    }

    private var footer: some View {
        HStack {
            Button("Add Repository", systemImage: "plus") { window.isAddingPool = true }
                .help("Add a git repository (⇧⌘O)")
            Spacer()
            if let appUpdate {
                Button("Update available", systemImage: "arrow.down.circle") { appUpdate.showDetails() }
                    .foregroundStyle(Color.accentColor)
                    .help("Watercoded \(appUpdate.version) is available. Click to review and install the update.")
                    .accessibilityLabel("Watercoded \(appUpdate.version) update available")
                    .accessibilityHint("Review and install the update")
            }
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Settings (⌘,)")
            Button("New Session", systemImage: "square.and.pencil") { window.beginNewCurrent() }
                .help("Start a new session (⌘N)")
                .disabled(workspace.pools.isEmpty)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.small)
    }

    private func delete(_ controller: CurrentController, removingWorktree: Bool) {
        if window.selection == controller.id {
            window.selection = nil
        }
        Task {
            do {
                try await workspace.delete(controller.id, removingWorktree: removingWorktree)
            } catch {
                window.present(error, title: "Couldn't Delete Session")
            }
        }
    }
}

/// Keeps each repository's disclosure state across launches without changing workspace data.
private struct PoolSection: View {
    let pool: Pool
    @Binding var pendingDeletion: CurrentController?
    @Environment(Workspace.self) private var workspace
    @Environment(WindowModel.self) private var window
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage private var isExpanded: Bool

    init(pool: Pool, pendingDeletion: Binding<CurrentController?>) {
        self.pool = pool
        _pendingDeletion = pendingDeletion
        _isExpanded = AppStorage(wrappedValue: true, Self.expansionKey(for: pool.id))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxSmall) {
            PoolHeader(pool: pool, isExpanded: $isExpanded)
                .padding(.leading, Spacing.small)
                .padding(.vertical, Spacing.xSmall)
            // Keep the content mounted so its height interpolates instead of deleting List rows.
            VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                let currents = workspace.currents(in: pool.id)
                if currents.isEmpty {
                    Button("Start a Session…") { window.beginNewCurrent(in: pool.id) }
                        .buttonStyle(.link)
                        .padding(Spacing.small)
                }
                ForEach(SidebarView.nested(currents)) { entry in
                    SidebarSessionButton(controller: entry.controller, showsPool: false, depth: entry.depth)
                        .contextMenu {
                            CurrentContextMenu(controller: entry.controller, pendingDeletion: $pendingDeletion)
                        }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(height: isExpanded ? nil : 0, alignment: .top)
            .clipped()
            .opacity(isExpanded ? 1 : 0)
            .allowsHitTesting(isExpanded)
            .accessibilityHidden(!isExpanded)
        }
        .animation(reduceMotion ? nil : Motion.standard, value: isExpanded)
    }

    static func expansionKey(for poolID: PoolID) -> String {
        "sidebar.repository.\(poolID).isExpanded"
    }
}

private struct SidebarSessionButton: View {
    let controller: CurrentController
    let showsPool: Bool
    var depth = 0
    @Environment(WindowModel.self) private var window
    @State private var isHovered = false

    var body: some View {
        Button {
            window.selection = controller.id
        } label: {
            CurrentRow(controller: controller, showsPool: showsPool)
                .padding(.leading, CGFloat(depth) * Spacing.large)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.small)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(
            Color.accentColor.opacity(window.selection == controller.id ? 0.18 : (isHovered ? 0.08 : 0)),
            in: RoundedRectangle(cornerRadius: Radius.small)
        )
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(window.selection == controller.id ? .isSelected : [])
    }
}

private struct PoolHeader: View {
    let pool: Pool
    @Binding var isExpanded: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(WindowModel.self) private var window
    @State private var isEditingFolders = false

    var body: some View {
        HStack {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: Spacing.small) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: Spacing.large, height: Spacing.large)
                    Label(pool.name, systemImage: "folder")
                    if let count = pool.additionalDirectories?.count, count > 0 {
                        Image(systemName: "folder.badge.plus")
                            .foregroundStyle(.secondary)
                            .help("\(count) extra \(count == 1 ? "folder" : "folders") shared with agents")
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .help("\(isExpanded ? "Collapse" : "Expand") \(pool.name)")
            .accessibilityLabel(pool.name)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint("\(isExpanded ? "Hide" : "Show") sessions in this repository")
            Button("New session", systemImage: "square.and.pencil") {
                window.beginNewCurrent(in: pool.id)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .frame(width: Spacing.xLarge, height: Spacing.xLarge)
            .contentShape(.rect)
            .help("Start a new session in \(pool.name)")
            .accessibilityLabel("New session in \(pool.name)")
        }
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $isEditingFolders) { RepositorySettingsSheet(pool: pool) }
        .contextMenu {
            Button("New Session…", systemImage: "square.and.pencil") { window.beginNewCurrent(in: pool.id) }
            Button("Import Sessions…", systemImage: "square.and.arrow.down") { window.importingInto = pool.id }
            Button("Repository Settings…", systemImage: "gearshape") { isEditingFolders = true }
            Divider()
            OpenInMenuItems(url: pool.rootURL)
            Divider()
            Button("Remove from Watercoded", systemImage: "minus.circle", role: .destructive) {
                Task { await workspace.removePool(pool.id) }
            }
        }
    }
}

private struct CurrentContextMenu: View {
    let controller: CurrentController
    @Binding var pendingDeletion: CurrentController?
    @Environment(Workspace.self) private var workspace
    @Environment(WindowModel.self) private var window

    @Environment(ProviderStatus.self) private var providers

    var body: some View {
        if controller.current.status == .settled {
            Button("Reopen", systemImage: "arrow.uturn.backward") { controller.reopen() }
        } else {
            Button("Land…", systemImage: "arrow.down.to.line") { window.landing = controller.id }
                .disabled(controller.isTurnActive)
            Button("Archive", systemImage: "archivebox") { Task { await controller.settle() } }
        }
        ContinueInTerminalButton(controller: controller)
        Menu("Run Again With") {
            ForEach(providers.registry.descriptors
                .filter { providers.availability(of: $0.id)?.isAvailable != false }) { descriptor in
                    Section(descriptor.displayName) {
                        let options = ModelOptions(descriptor: descriptor, providers: providers, workspace: workspace)
                        ForEach(options.models) { model in
                            Button(options.name(for: model)) { rerun(
                                descriptor.id,
                                model: model.isDefault ? nil : model.id
                            ) }
                        }
                    }
                }
        }
        Divider()
        Button("Export as Markdown…", systemImage: "square.and.arrow.up") { Task { await exportMarkdown() } }
        Button("Copy as Markdown", systemImage: "doc.richtext") {
            Task {
                let text = await workspace.markdown(for: controller.id)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
        Button("Copy Branch Name", systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(controller.current.channel.branch, forType: .string)
        }
        Menu("Open In") { OpenInMenuItems(url: controller.current.channel.url) }
        if workspace.canRecordReplays {
            Button("Save as Replay Script", systemImage: "play.rectangle.on.rectangle") { saveReplay() }
        }
        Divider()
        Button("Delete…", systemImage: "trash", role: .destructive) { pendingDeletion = controller }
    }

    private func rerun(_ providerID: ProviderID, model: String?) {
        Task {
            do {
                window.selection = try await workspace.rerun(controller.id, providerID: providerID, model: model).id
            } catch {
                window.present(error, title: "Couldn't Start the Re-run")
            }
        }
    }

    private func exportMarkdown() async {
        let text = await workspace.markdown(for: controller.id)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = Slug.make(from: controller.current.title) + ".md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            window.present(error, title: "Couldn't Export")
        }
    }

    private func saveReplay() {
        do {
            let url = try workspace.saveReplayScript(for: controller.id)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            window.present(error, title: "Couldn't Save Replay Script")
        }
    }
}
