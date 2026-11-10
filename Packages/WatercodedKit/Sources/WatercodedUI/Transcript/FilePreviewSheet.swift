import AppKit
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers
import WatercodedDesign

/// Documents open inside Watercoded, without depending on a file association or executing a script.
struct FilePreviewSheet: View {
    let reference: LocalFileReference
    @Environment(\.dismiss) private var dismiss
    @State private var text: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            HStack {
                VStack(alignment: .leading) {
                    Text(reference.url.lastPathComponent).font(.headline)
                    Text(reference.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if let line = reference.line {
                        Text("Line \(line)" + (reference.column.map { ", column \($0)" } ?? "")).font(.caption)
                    }
                }
                Spacer()
                Menu("Open in", systemImage: "arrow.up.forward.app") {
                    OpenInMenuItems(url: reference.url)
                }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Divider()
            if let text {
                if ["md", "markdown"].contains(reference.url.pathExtension.lowercased()), reference.line == nil {
                    ScrollView { MarkdownView(text: text).padding(Spacing.medium) }
                        .transcriptLinks(relativeTo: reference.url.deletingLastPathComponent())
                } else {
                    source(text)
                }
            } else {
                DocumentPreview(url: reference.url)
            }
        }
        .padding(Spacing.large)
        .frame(minWidth: 600, idealWidth: 800, minHeight: 420, idealHeight: 600)
        .task(id: reference) {
            text = Self.textContents(of: reference.url)
        }
    }

    /// An ASCII-only PDF or an SVG must still use a document/image preview rather than a source listing.
    static func textContents(of url: URL) -> String? {
        let type = UTType(filenameExtension: url.pathExtension)
        guard type == nil || type?.conforms(to: .text) == true,
              type?.conforms(to: .image) != true, type != .rtf else { return nil }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
        return size <= 2_000_000 ? try? String(contentsOf: url, encoding: .utf8) : nil
    }

    private func source(_ text: String) -> some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { index, line in
                        HStack(alignment: .top) {
                            Text("\(index + 1)").foregroundStyle(.secondary).frame(width: 45, alignment: .trailing)
                            Text(line.isEmpty ? " " : line).textSelection(.enabled)
                        }
                        .padding(.horizontal, Spacing.small)
                        .background(index + 1 == reference.line ? Color.accentColor.opacity(0.15) : .clear)
                        .id(index + 1)
                    }
                }
                .font(.system(.callout, design: .monospaced))
            }
            .onAppear {
                if let line = reference.line {
                    proxy.scrollTo(line, anchor: .center)
                }
            }
        }
    }
}

private struct DocumentPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSView {
        guard let view = QLPreviewView(frame: .zero, style: .normal) else {
            return NSTextField(labelWithString: "A preview couldn't be created. Use Open in to view this file.")
        }
        view.shouldCloseWithWindow = false
        view.autostarts = false
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? QLPreviewView)?.previewItem = url as NSURL
    }

    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        (view as? QLPreviewView)?.close()
    }
}
