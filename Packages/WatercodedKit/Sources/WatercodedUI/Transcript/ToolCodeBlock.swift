import AppKit
import SwiftUI
import WatercodedDesign

/// Readable, selectable tool text. Copy always includes the complete text, even when the display is capped.
struct ToolCodeBlock: View {
    let title: String
    let text: String
    @State private var showFullText = false

    private static let displayLimit = 20000

    private var isTruncated: Bool {
        !showFullText && text.count > Self.displayLimit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Copy \(title.lowercased())")
                .accessibilityLabel("Copy \(title.lowercased())")
            }
            ScrollView(.vertical) {
                Text(verbatim: isTruncated ? String(text.prefix(Self.displayLimit)) : text)
                    .font(.system(.callout, design: .monospaced))
                    .lineSpacing(Spacing.xSmall)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.medium)
            }
            .frame(maxHeight: 320)
            .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
            if isTruncated {
                Button("Show all \(text.count.formatted()) characters") {
                    showFullText = true
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }
        }
    }
}
