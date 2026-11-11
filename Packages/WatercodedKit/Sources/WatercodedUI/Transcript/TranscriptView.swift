import Orchestrator
import SwiftUI
import WatercodedCore
import WatercodedDesign

/// The conversation, newest at the bottom, following new content as it arrives.
struct TranscriptView: View {
    let controller: CurrentController
    @Environment(WindowModel.self) private var window
    @State private var expansion: ToolExpansion
    @State private var position = ScrollPosition(idType: UUID.self, edge: .bottom)
    @State private var highlightedItem: UUID?
    @State private var followsOutput = true
    @State private var isUserScrolling = false
    @State private var scrollTask: Task<Void, Never>?

    init(controller: CurrentController, expansion: ToolExpansion = ToolExpansion()) {
        self.controller = controller
        _expansion = State(initialValue: expansion)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.xLarge) {
                TranscriptHistory(controller: controller, highlightedItem: highlightedItem)
                TranscriptTail(controller: controller)
                Color.clear.frame(height: 1)
            }
            .scrollTargetLayout()
            .frame(maxWidth: Metrics.readableWidth, alignment: .leading)
            .padding(.vertical, Spacing.xLarge)
            .padding(.horizontal, Spacing.large)
            .frame(maxWidth: .infinity)
        }
        .environment(expansion)
        // Keep a real row anchored when wrapping changes, including inspector resizing.
        .scrollPosition($position, anchor: .bottom)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        // Short transcripts keep a stable origin as their first rows arrive. Bottom alignment
        // of an estimated lazy height can repeatedly invalidate the window's constraints.
        .defaultScrollAnchor(.top, for: .alignment)
        .onScrollPhaseChange { _, phase, context in
            isUserScrolling = phase == .interacting || phase == .decelerating
            if isUserScrolling {
                followsOutput = Self.nearBottom(context.geometry)
            }
        }
        .onScrollGeometryChange(for: Bool.self) { Self.nearBottom($0) } action: { _, near in
            if isUserScrolling {
                followsOutput = near
            } else if !near {
                // Only correct a departure from the bottom. Reacting to every estimated
                // content-size change creates a scroll/layout/scroll feedback loop.
                scheduleScroll()
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { _ in
            scheduleScroll()
        }
        .onChange(of: controller.transcript.count) { scheduleScroll() }
        .onChange(of: controller.streamingText) { scheduleScroll() }
        .onChange(of: window.highlightedItem, initial: true) { _, item in
            guard let item, controller.transcript.contains(where: { $0.id == item }) else { return }
            // Navigation requests are consumed once; reopening a session must not replay one.
            window.highlightedItem = nil
            highlightedItem = item
            followsOutput = false
            scrollTask?.cancel()
            scrollTask = nil
            withAnimation(Motion.standard) { position.scrollTo(id: item, anchor: .center) }
        }
        .onDisappear {
            scrollTask?.cancel()
            scrollTask = nil
        }
    }

    private static func nearBottom(_ geometry: ScrollGeometry) -> Bool {
        geometry.contentOffset.y + geometry.containerSize.height >=
            geometry.contentSize.height + geometry.contentInsets.bottom - 80
    }

    private func scheduleScroll() {
        guard followsOutput, scrollTask == nil else { return }
        scrollTask = Task {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            defer { scrollTask = nil }
            guard followsOutput, !isUserScrolling else { return }
            position.scrollTo(edge: .bottom)
        }
    }
}

/// History does not observe streaming text, so token updates don't regroup every earlier row.
private struct TranscriptHistory: View {
    let controller: CurrentController
    let highlightedItem: UUID?

    var body: some View {
        let layout = TranscriptLayout(controller.transcript)
        ForEach(layout.topLevel) { item in
            let highlighted = isHighlighted(item)
            TranscriptRow(item: item, controller: controller, subagentCalls: layout.children)
                .padding(highlighted ? Spacing.small : 0)
                .background {
                    if highlighted {
                        RoundedRectangle(cornerRadius: Radius.medium).fill(Color.accentColor.opacity(0.12))
                    }
                }
        }
    }

    private func isHighlighted(_ item: TranscriptItem) -> Bool {
        if case .question = item.content {
            return false
        }
        return highlightedItem == item.id
    }
}

private struct TranscriptTail: View {
    let controller: CurrentController

    var body: some View {
        if !controller.streamingText.isEmpty {
            AssistantMessageView(text: controller.streamingText, isStreaming: true)
        } else if controller.isTurnActive, !controller.isAwaitingUser {
            WorkingIndicator()
        }
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
