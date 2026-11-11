import AppKit
import SwiftUI
import WatercodedDesign

/// A code pane whose viewport size never depends on native text measurement.
/// TextKit lays out and scrolls its document inside that viewport; the lazy transcript
/// receives only a bounded size, even when text wraps or a command's output changes.
struct ToolTextView: NSViewRepresentable {
    let title: String
    let text: String
    let height: CGFloat

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: Metrics.readableWidth, height: height))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let editor = NSTextView(usingTextLayoutManager: true)
        editor.isEditable = false
        editor.isSelectable = true
        editor.drawsBackground = false
        editor.isRichText = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.frame = NSRect(origin: .zero, size: scroll.contentSize)
        editor.textContainer?.containerSize = NSSize(
            width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude
        )
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.heightTracksTextView = false
        editor.textContainerInset = NSSize(width: Spacing.medium, height: Spacing.medium)
        editor.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        editor.textColor = .labelColor
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = Spacing.xSmall
        editor.defaultParagraphStyle = paragraph
        editor.setAccessibilityLabel(title)
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? NSTextView else { return }
        editor.setAccessibilityLabel(title)
        guard editor.string != text else { return }
        let selection = editor.selectedRange()
        let origin = scroll.contentView.bounds.origin
        editor.string = text
        if NSMaxRange(selection) <= (text as NSString).length {
            editor.setSelectedRange(selection)
        }
        scroll.contentView.scroll(to: origin)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        // In particular, never call fittingSize/intrinsicContentSize on the text view here.
        CGSize(width: proposal.width ?? Metrics.readableWidth, height: height)
    }
}
