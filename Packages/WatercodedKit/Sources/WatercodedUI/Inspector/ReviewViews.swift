import Orchestrator
import SwiftUI
import WatercodedDesign

/// A small editor for one review comment.
struct CommentEditor: View {
    let title: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text(title).font(.headline).lineLimit(1)
            TextField("What should change?", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2 ... 6)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add Comment") {
                    onSave(text)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Spacing.medium)
        .frame(width: 340)
    }
}

/// Pending review comments, sent to the agent together as one message.
struct ReviewTray: View {
    let controller: CurrentController
    @State private var summary = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text("Review (\(controller.reviewComments.count))").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xSmall) {
                    ForEach(controller.reviewComments) { comment in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                                Text(comment.path + (comment.lines.isEmpty ? "" : " · \(comment.lines)"))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                Text(comment.text).font(.callout)
                            }
                            Spacer()
                            Button("Remove", systemImage: "xmark") { controller.removeReviewComment(comment.id) }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
            .frame(maxHeight: 160)
            TextField("Overall note (optional)", text: $summary)
                .textFieldStyle(.roundedBorder)
            Button("Send Review to Agent") {
                let note = summary
                Task {
                    if await controller.sendReview(summary: note), summary == note {
                        summary = ""
                    }
                }
            }
            .buttonStyle(.glassProminent)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .disabled(controller
                .isSendingReview || (controller.isTurnActive && !controller.capabilities.contains(.queueing)))
        }
        .padding(Spacing.medium)
    }
}
