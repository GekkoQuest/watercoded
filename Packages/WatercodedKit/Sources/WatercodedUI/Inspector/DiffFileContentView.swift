import AppKit
import GitKit
import Orchestrator
import SwiftUI
import WatercodedDesign

/// A bounded viewport is essential: a generated file can contain tens of thousands of lines.
/// Virtualize individual lines rather than hiding an eager hunk stack inside a lazy file row.
struct DiffFileContentView: View {
    let file: FileDiff
    let canRevert: Bool

    var body: some View {
        let rows = DiffFileLayout(file: file).rows
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows, id: \.self) { row in
                    let hunk = file.hunks[row.hunk]
                    if let line = row.line {
                        DiffLineView(line: hunk.lines[line])
                    } else {
                        DiffHunkHeaderView(hunk: hunk, file: file, canRevert: canRevert)
                    }
                }
            }
        }
        .frame(height: min(
            Metrics.diffPreviewMaxHeight,
            CGFloat(rows.count) * Metrics.diffPreviewRowHeight + Spacing.small
        ))
        .accessibilityLabel("Changes in \(file.path)")
    }
}

/// Stable indices let unchanged rows survive polling without retaining a view per source line.
struct DiffFileLayout {
    struct Row: Hashable {
        let hunk: Int
        let line: Int?
    }

    let rows: [Row]

    init(file: FileDiff) {
        rows = file.hunks.indices.flatMap { index in
            [Row(hunk: index, line: nil)] + file.hunks[index].lines.indices.map {
                Row(hunk: index, line: $0)
            }
        }
    }
}

struct DiffHunkHeaderView: View {
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
        }
        .textSelection(.enabled)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Copy change", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(excerpt, forType: .string)
            }
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
        .textSelection(.enabled)
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
