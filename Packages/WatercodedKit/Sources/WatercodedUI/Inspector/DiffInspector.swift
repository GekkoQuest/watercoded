import GitKit
import Orchestrator
import SwiftUI
import WatercodedCore
import WatercodedDesign

/// Changes in the Current's channel, for the whole session or a single turn, refreshed as the
/// agent edits. Files and hunks can be reverted, opened, or sent to the agent with a question.
struct DiffInspector: View {
    let controller: CurrentController
    @Environment(Workspace.self) private var workspace
    @Environment(WindowModel.self) private var window
    @State private var scope = ChangeScope.session
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
                in: controller.id
            ) } },
            revertHunk: { hunk, file in
                await perform("Couldn't Revert Change") { try await workspace.revert(hunk, of: file, in: controller.id)
                }
            },
            ask: { prompt in controller.draft += (controller.draft.isEmpty ? "" : "\n\n") + prompt },
            comment: { controller.addReviewComment($0) },
            channelURL: controller.current.channel.url
        ))
        // Reloads automatically whenever the agent may have touched files.
        .task(id: ReloadKey(revision: controller.activity.fileChangeRevision, scope: scope)) { await reload() }
    }

    private struct ReloadKey: Hashable {
        let revision: Int
        let scope: ChangeScope
    }

    /// Lives inside the inspector (not the window toolbar) so it's only shown with the changes.
    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack(spacing: Spacing.small) {
                Text("Changes").font(.headline)
                if let diff, !diff.isEmpty {
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
            if let snapshots = controller.current.turnSnapshots, !snapshots.isEmpty {
                Picker("Show", selection: $scope) {
                    Text("Whole session").tag(ChangeScope.session)
                    ForEach(snapshots.reversed()) { snapshot in
                        Text(turnTitle(snapshot, isLatest: snapshot.index == snapshots.last?.index))
                            .tag(ChangeScope.turn(snapshot.index))
                    }
                }
                .labelsHidden()
                .help("Show everything the agent changed, or only what one turn changed")
            }
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.small)
    }

    @ViewBuilder private var content: some View {
        if let errorMessage {
            ContentUnavailableView(
                "Couldn't Load Changes",
                systemImage: "exclamationmark.triangle",
                description: Text(errorMessage)
            )
        } else if let diff, diff.isEmpty {
            ContentUnavailableView(
                "No Changes",
                systemImage: "checkmark.circle",
                description: Text(scope == .session ? "Edits the agent makes appear here." :
                    "This turn didn't change any files.")
            )
        } else if let diff {
            List {
                Section("\(diff.files.count) \(diff.files.count == 1 ? "file" : "files") changed") {
                    ForEach(diff.files) { FileDiffView(file: $0, canRevert: scope == .session) }
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

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            diff = try await workspace.diff(for: controller.id, scope: scope)
            errorMessage = nil
        } catch is CancellationError {
            // A newer reload replaced this one (the agent changed more files); keep what's shown.
        } catch {
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
    @Environment(\.diffActions) private var actions
    @State private var isExpanded = true
    @State private var isConfirmingRevert = false
    @State private var isCommenting = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if file.isBinary {
                Text("Binary file").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: Spacing.small) {
                    ForEach(Array(file.hunks.enumerated()), id: \.offset) { _, hunk in
                        HunkView(hunk: hunk, file: file, canRevert: canRevert && file.change == .modified)
                    }
                }
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

private struct HunkView: View {
    let hunk: Hunk
    let file: FileDiff
    let canRevert: Bool
    @Environment(\.diffActions) private var actions
    @State private var isHovering = false
    @State private var isCommenting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Spacing.small) {
                Text(hunk.header)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if isHovering || isCommenting {
                    Button("Comment", systemImage: "text.bubble") { isCommenting = true }
                        .help("Add a review comment; send all comments together as one review")
                        .popover(isPresented: $isCommenting) {
                            CommentEditor(title: "Comment on lines \(file.lineRange(of: hunk))") { text in
                                actions.comment(ReviewComment(
                                    path: file.path, lines: file.lineRange(of: hunk), excerpt: excerpt, text: text
                                ))
                            }
                        }
                    Button("Ask", systemImage: "bubble.left") { askAboutHunk() }
                        .help("Ask the agent about this change")
                    if canRevert {
                        Button("Revert", systemImage: "arrow.uturn.backward") {
                            Task { await actions.revertHunk(hunk, file) }
                        }
                        .help("Undo just this change")
                    }
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .padding(.vertical, Spacing.xxSmall)
            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                DiffLineView(line: line)
            }
        }
        .textSelection(.enabled)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Add Review Comment…", systemImage: "text.bubble") { isCommenting = true }
            Button("Ask the Agent About This Change", systemImage: "bubble.left") { askAboutHunk() }
            if canRevert {
                Button("Revert This Change", systemImage: "arrow.uturn.backward") {
                    Task { await actions.revertHunk(hunk, file) }
                }
            }
        }
    }

    /// The hunk as diff text, without file headers.
    private var excerpt: String {
        file.patch(for: hunk).split(separator: "\n").dropFirst(3).joined(separator: "\n")
    }

    private func askAboutHunk() {
        actions
            .ask("About this change in `\(file.path)` (lines \(file.lineRange(of: hunk))):\n```diff\n\(excerpt)\n```\n")
    }
}

private struct DiffLineView: View {
    let line: DiffLine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.small) {
            Text(marker).foregroundStyle(color).frame(width: 10)
            Text(line.text.isEmpty ? " " : line.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.horizontal, Spacing.xSmall)
        .background(color.opacity(line.kind == .context ? 0 : 0.12))
    }

    private var marker: String {
        switch line.kind {
        case .addition: "+"
        case .deletion: "−"
        case .context: " "
        }
    }

    private var color: Color {
        switch line.kind {
        case .addition: .green
        case .deletion: .red
        case .context: .primary
        }
    }
}
