import Orchestrator
import SwiftUI
import WatercodedCore
import WatercodedDesign

/// The conversation, newest at the bottom, following new content as it arrives.
struct TranscriptView: View {
    let controller: CurrentController
    @Environment(WindowModel.self) private var window
    private let bottomID = "transcript-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.xLarge) {
                    let layout = TranscriptLayout(controller.transcript)
                    ForEach(layout.topLevel) { item in
                        TranscriptRow(item: item, controller: controller, subagentCalls: layout.children)
                            .padding(isHighlighted(item) ? Spacing.small : 0)
                            .background {
                                if isHighlighted(item) {
                                    RoundedRectangle(cornerRadius: Radius.medium).fill(Color.accentColor.opacity(0.12))
                                }
                            }
                    }
                    if !controller.streamingText.isEmpty {
                        AssistantMessageView(text: controller.streamingText, isStreaming: true)
                    } else if controller.isTurnActive, !controller.isAwaitingUser {
                        WorkingIndicator()
                    }
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .frame(maxWidth: Metrics.readableWidth, alignment: .leading)
                .padding(.vertical, Spacing.xLarge)
                .padding(.horizontal, Spacing.large)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: controller.transcript.count) { proxy.scrollTo(bottomID, anchor: .bottom) }
            .onChange(of: window.highlightedItem, initial: true) { _, item in
                guard let item, controller.transcript.contains(where: { $0.id == item }) else { return }
                withAnimation(Motion.standard) { proxy.scrollTo(item, anchor: .center) }
            }
            .onChange(of: controller.streamingText) { proxy.scrollTo(bottomID, anchor: .bottom) }
        }
    }

    private func isHighlighted(_ item: TranscriptItem) -> Bool {
        // Question cards already have their own surface. The Answer shortcut should scroll to
        // them without adding another box around the card.
        if case .question = item.content {
            return false
        }
        return window.highlightedItem == item.id
    }
}

/// Splits the transcript into top-level rows and the tool calls subagents made, which are shown
/// nested inside their Task card instead of mixed into the main conversation.
struct TranscriptLayout {
    let topLevel: [TranscriptItem]
    let children: [String: [ToolCallRecord]]

    init(_ transcript: [TranscriptItem]) {
        var topLevel: [TranscriptItem] = []
        var children: [String: [ToolCallRecord]] = [:]
        for (index, item) in transcript.enumerated() {
            // Older image-only messages saved the provider's fallback prompt as user text.
            if case let .user(text) = item.content,
               index > 0, case .userImages = transcript[index - 1].content,
               text.isEmpty || text == "(See the attached image.)" {
                continue
            }
            if case let .toolCall(record) = item.content, let parent = record.parentCallID {
                children[parent, default: []].append(record)
            } else {
                topLevel.append(item)
            }
        }
        self.topLevel = topLevel
        self.children = children
    }
}

private struct TranscriptRow: View {
    let item: TranscriptItem
    let controller: CurrentController
    let subagentCalls: [String: [ToolCallRecord]]

    var body: some View {
        switch item.content {
        case let .user(text):
            UserMessageView(text: text)
                .contextMenu { BranchMenuItems(controller: controller, messageID: item.id) }
        case let .userImages(count):
            if let images = item.images, !images.isEmpty {
                ImageAttachmentsView(images: images, alignment: .trailing)
                    .contextMenu {
                        if let messageID = attachedMessageID {
                            BranchMenuItems(controller: controller, messageID: messageID)
                        }
                    }
            } else {
                HStack {
                    Spacer()
                    Label("\(count) \(count == 1 ? "image" : "images") attached", systemImage: "photo")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .help("This older transcript saved only the image count; previews are unavailable.")
                }
            }
        case let .assistant(text): AssistantMessageView(text: text, isStreaming: false)
        case let .toolCall(record): ToolCallView(record: record, children: subagentCalls[record.callID] ?? [])
        case let .notice(notice): NoticeView(notice: notice)
        case let .thinking(record): ThinkingView(record: record)
        case let .plan(record): PlanCard(record: record, controller: controller)
        case let .question(record): QuestionCard(record: record, controller: controller)
        case let .form(record): FormCard(record: record, controller: controller)
        }
    }

    private var attachedMessageID: TranscriptItem.ID? {
        guard let index = controller.transcript.firstIndex(where: { $0.id == item.id }),
              index + 1 < controller.transcript.count,
              case .user = controller.transcript[index + 1].content else { return nil }
        return controller.transcript[index + 1].id
    }
}

private struct WorkingIndicator: View {
    var body: some View {
        HStack(spacing: Spacing.small) {
            ProgressView().controlSize(.small)
            Text("Working…").foregroundStyle(.secondary)
        }
        .font(.callout)
        .accessibilityLabel("The agent is working")
    }
}
