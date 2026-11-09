import Orchestrator
import SwiftUI
import WatercodedDesign

/// Worktrees on disk, their size and whether a session still uses them, with cleanup.
/// Removing a worktree keeps its branch, so an archived session that's reopened gets it back.
struct StorageSettings: View {
    @Environment(Workspace.self) private var workspace
    @State private var items: [WorktreeInfo]?
    @State private var isConfirmingCleanup = false
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            if let items {
                if items.isEmpty {
                    ContentUnavailableView(
                        "No Worktrees",
                        systemImage: "externaldrive",
                        description: Text("Sessions that run in their own worktree appear here.")
                    )
                } else {
                    List(items) { row($0) }
                        .listStyle(.inset)
                    footer(items)
                }
            } else {
                ProgressView("Measuring worktrees…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(Spacing.large)
        .task { await reload() }
        .alert("Couldn't Remove Worktree", isPresented: Binding(
            get: { errorMessage != nil },
            set: {
                if !$0 {
                    errorMessage = nil
                }
            }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func row(_ item: WorktreeInfo) -> some View {
        HStack(spacing: Spacing.medium) {
            VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                Text(item.sessionTitle ?? item.url.lastPathComponent).lineLimit(1)
                HStack(spacing: Spacing.xSmall) {
                    Text(item.url.deletingLastPathComponent().lastPathComponent)
                    if let modified = item.modified {
                        Text("· changed \(modified, format: .relative(presentation: .named))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            Text(Self.useLabel(item.use)).font(.caption).foregroundStyle(item.use == .active ? .secondary : .primary)
            Text(item.sizeBytes.map { Self.bytes($0) } ?? "—")
                .font(.callout.monospacedDigit())
                .frame(width: 70, alignment: .trailing)
            Button("Remove", systemImage: "trash") { Task { await remove([item]) } }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(!item.isRemovable || isWorking)
                .help(item
                    .isRemovable ? "Remove this worktree. Its branch is kept." : "An open session uses this worktree")
        }
        .contextMenu { OpenInMenuItems(url: item.url) }
    }

    private func footer(_ items: [WorktreeInfo]) -> some View {
        let removable = items.filter(\.isRemovable)
        let total = removable.compactMap(\.sizeBytes).reduce(0, +)
        return HStack {
            Text("Branches are kept, so archived sessions get their worktree back when reopened.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Remove Unused (\(removable.count) · \(Self.bytes(total)))") { isConfirmingCleanup = true }
                .disabled(removable.isEmpty || isWorking)
                .confirmationDialog(
                    "Remove \(removable.count) worktrees?",
                    isPresented: $isConfirmingCleanup
                ) {
                    Button("Remove \(Self.bytes(total))", role: .destructive) { Task { await remove(removable) } }
                } message: {
                    Text("Uncommitted changes in them are lost. Their branches and commits are kept.")
                }
        }
    }

    private func reload() async {
        items = await workspace.worktreeInventory()
    }

    private func remove(_ targets: [WorktreeInfo]) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await workspace.removeWorktrees(targets)
        } catch {
            errorMessage = error.localizedDescription
        }
        await reload()
    }

    static func useLabel(_ use: WorktreeInfo.Use) -> String {
        switch use {
        case .active: "In use"
        case .archived: "Archived"
        case .unused: "Unused"
        }
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
