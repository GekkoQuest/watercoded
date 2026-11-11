import GitKit
import Orchestrator
import SwiftUI
import WatercodedCore
import WatercodedDesign

/// Uncommitted changes, session history or a single turn, refreshed as the
/// agent edits. Files and hunks can be reverted, opened, or sent to the agent with a question.
struct DiffInspector: View {
    let controller: CurrentController
    @Environment(Workspace.self) private var workspace
    @Environment(WindowModel.self) private var window
    @Environment(\.scenePhase) private var scenePhase
    @State private var scope = ChangeScope.uncommitted
    @State private var loadedScope: ChangeScope?
    @State private var reloadID = UUID()
    @State private var diff: UnifiedDiff?
    @State private var errorMessage: String?
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !controller.reviewComments.isEmpty {
                Divider()
                ReviewTray(controller: controller)
            }
        }
        .environment(\.diffActions, DiffActions(
            revertFile: { file in await perform("Couldn't Revert File") { try await workspace.revert(
                file,
                in: controller.id, scope: scope
            ) } },
            revertHunk: { hunk, file in
                await perform("Couldn't Revert Change") { try await workspace.revert(
                    hunk,
                    of: file,
                    in: controller.id,
                    scope: scope
                )
                }
            },
            ask: { prompt in controller.draft += (controller.draft.isEmpty ? "" : "\n\n") + prompt },
            comment: { controller.addReviewComment($0) },
            channelURL: controller.current.channel.url
        ))
        // Poll only while this inspector is visible and the app is active, including external commits/edits.
        .task(id: ReloadKey(
            currentID: controller.id, revision: controller.activity.fileChangeRevision,
            scope: scope, isActive: scenePhase == .active
        )) {
            guard scenePhase == .active else { return }
            await reload()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                await reload(showProgress: false)
            }
        }
    }

    private struct ReloadKey: Hashable {
        let currentID: CurrentID
        let revision: Int
        let scope: ChangeScope
        let isActive: Bool
    }

    /// Lives inside the inspector (not the window toolbar) so it's only shown with the changes.
    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack(spacing: Spacing.small) {
                Text("Changes").font(.headline)
                if let diff, loadedScope == scope, !diff.isEmpty {
                    Text("+\(diff.additions)").foregroundStyle(.green)
                    Text("−\(diff.deletions)").foregroundStyle(.red)
                }
                Spacer()
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Reload Changes", systemImage: "arrow.clockwise") { Task { await reload() } }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Reload changes (they also update automatically as the agent works)")
                }
            }
            .monospacedDigit()
            Picker("Show", selection: $scope) {
                Text("Uncommitted changes").tag(ChangeScope.uncommitted)
                Text("Whole session").tag(ChangeScope.session)
                if let snapshots = controller.current.turnSnapshots {
                    ForEach(snapshots.reversed()) { snapshot in
                        Text(turnTitle(snapshot, isLatest: snapshot.index == snapshots.last?.index))
                            .tag(ChangeScope.turn(snapshot.index))
                    }
                }
            }
            .labelsHidden()
            .help("Show uncommitted changes, the whole session including commits, or a single turn")
            if scope == .session {
                Text("Includes committed changes since this session started.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.small)
    }

    @ViewBuilder private var content: some View {
        if loadedScope != scope, errorMessage == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            ContentUnavailableView(
                "Couldn't Load Changes",
                systemImage: "exclamationmark.triangle",
                description: Text(errorMessage)
            )
        } else if let diff, diff.isEmpty {
            ContentUnavailableView(
                scope == .uncommitted ? "No uncommitted changes" : "No changes",
                systemImage: "checkmark.circle",
                description: Text(emptyDescription)
            )
        } else if let diff {
            List {
                Section("\(diff.files.count) \(diff.files.count == 1 ? "file" : "files") changed") {
                    ForEach(diff.files) {
                        FileDiffView(
                            file: $0, canRevert: scope == .session || scope == .uncommitted,
                            revertsToLatestCommit: scope == .uncommitted
                        )
                    }
                }
            }
            .listStyle(.inset)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func turnTitle(_ snapshot: TurnSnapshot, isLatest: Bool) -> String {
        let time = snapshot.startedAt.formatted(date: .omitted, time: .shortened)
        let running = snapshot.afterCommit == nil ? " (in progress)" : ""
        return isLatest ? "Last turn · \(time)\(running)" : "Turn \(snapshot.index) · \(time)"
    }

    private var emptyDescription: String {
        switch scope {
        case .uncommitted: "The working tree is clean. Whole session shows earlier committed work."
        case .session: "Edits the agent makes appear here."
        case .turn: "This turn didn't change any files."
        }
    }

    private func reload(showProgress: Bool = true) async {
        let request = UUID()
        let requestedScope = scope
        reloadID = request
        if showProgress {
            isLoading = true
        }
        defer {
            if reloadID == request {
                isLoading = false
            }
        }
        do {
            let updated = try await workspace.diff(for: controller.id, scope: requestedScope)
            try Task.checkCancellation()
            guard reloadID == request, scope == requestedScope else { return }
            if diff != updated || loadedScope != requestedScope {
                diff = updated
            }
            loadedScope = requestedScope
            errorMessage = nil
        } catch is CancellationError {
            // A newer reload replaced this one (the agent changed more files); keep what's shown.
        } catch {
            guard reloadID == request, scope == requestedScope else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func perform(_ failureTitle: String, _ action: () async throws -> Void) async {
        do {
            try await action()
        } catch {
            window.present(error, title: failureTitle)
        }
    }
}

/// What a file or hunk row can do, provided by the inspector.
struct DiffActions {
    var revertFile: (FileDiff) async -> Void = { _ in }
    var revertHunk: (Hunk, FileDiff) async -> Void = { _, _ in }
    var ask: (String) -> Void = { _ in }
    var comment: (ReviewComment) -> Void = { _ in }
    var channelURL: URL?
}

extension EnvironmentValues {
    @Entry var diffActions = DiffActions()
}

private struct FileDiffView: View {
    let file: FileDiff
    let canRevert: Bool
    let revertsToLatestCommit: Bool
    @Environment(\.diffActions) private var actions
    @State private var isExpanded = true
    @State private var isConfirmingRevert = false
    @State private var isCommenting = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if file.isBinary {
                Text("Binary file").foregroundStyle(.secondary)
            } else {
                DiffFileContentView(file: file, canRevert: canRevert && file.change == .modified)
            }
        } label: {
            HStack {
                Image(systemName: symbolName).foregroundStyle(.secondary)
                Text(file.path).lineLimit(1).truncationMode(.head)
                Spacer()
                Text("+\(file.additions) −\(file.deletions)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .contextMenu { menu }
            .popover(isPresented: $isCommenting) {
                CommentEditor(title: "Comment on \(file.path)") { text in
                    actions.comment(ReviewComment(path: file.path, lines: "", excerpt: nil, text: text))
                }
            }
        }
        .confirmationDialog("Revert “\(file.path)”?", isPresented: $isConfirmingRevert) {
            Button(file.change == .added ? "Delete File" : "Revert File", role: .destructive) {
                Task { await actions.revertFile(file) }
            }
        } message: {
            Text(file.change == .added
                ? "The agent created this file. Reverting deletes it."
                : revertsToLatestCommit
                ? "The file goes back to its latest committed version."
                : "The file goes back to how it was when this session started.")
        }
    }

    @ViewBuilder private var menu: some View {
        Button("Ask the Agent About This File", systemImage: "bubble.left") {
            actions.ask("About `\(file.path)`: ")
        }
        Button("Comment on File…", systemImage: "text.bubble") { isCommenting = true }
        if canRevert {
            Button("Revert File…", systemImage: "arrow.uturn.backward", role: .destructive) {
                isConfirmingRevert = true
            }
        }
        if let base = actions.channelURL, file.change != .deleted {
            Divider()
            OpenInMenuItems(url: base.appending(path: file.path))
        }
    }

    private var symbolName: String {
        switch file.change {
        case .added: "plus.square"
        case .deleted: "minus.square"
        case .modified: "pencil"
        case .renamed: "arrow.right.square"
        }
    }
}
