import SwiftUI
import WatercodedCore
import WatercodedDesign

struct UserMessageView: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: Spacing.xxLarge * 2)
            Text(MarkdownInline.plain(text))
                .textSelection(.enabled)
                .padding(.horizontal, Spacing.large)
                .padding(.vertical, Spacing.medium)
                .glassEffect(
                    .regular.tint(.accentColor.opacity(0.25)),
                    in: RoundedRectangle(cornerRadius: Radius.large)
                )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You: \(text)")
    }
}

struct AssistantMessageView: View {
    let text: String
    let isStreaming: Bool

    var body: some View {
        MarkdownView(text: text)
            .opacity(isStreaming ? 0.92 : 1)
    }
}

struct NoticeView: View {
    let notice: Notice

    var body: some View {
        Label { Text(MarkdownInline.parse(notice.text)) } icon: { Image(systemName: symbolName) }
            .font(.callout)
            .foregroundStyle(color)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var symbolName: String {
        switch notice.level {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }

    private var color: Color {
        switch notice.level {
        case .info: .secondary
        case .warning: .orange
        case .error: .red
        }
    }
}
