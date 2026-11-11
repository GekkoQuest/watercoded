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
            ToolTextView(
                title: title,
                text: isTruncated ? String(text.prefix(Self.displayLimit)) : text,
                height: previewHeight
            )
            .frame(height: previewHeight)
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

    private var previewHeight: CGFloat {
        // A stable viewport based on hard lines, not wrapping or a proposed parent height.
        // Bound the scan too: choosing Show all must not repeatedly scan huge outputs for layout.
        let lines = text.utf8.prefix(Self.displayLimit).filter { $0 == 10 }.count + 1
        return min(
            Metrics.toolPreviewMaxHeight,
            CGFloat(max(3, lines)) * Metrics.toolPreviewLineHeight + Spacing.medium * 2
        )
    }
}
