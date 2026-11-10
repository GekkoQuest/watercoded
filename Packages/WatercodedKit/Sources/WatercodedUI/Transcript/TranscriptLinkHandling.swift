import AppKit
import SwiftUI

extension EnvironmentValues {
    @Entry var transcriptDirectory: URL?
}

extension View {
    /// Uses in-app previews for local files and the user's browser for ordinary web links.
    func transcriptLinks(relativeTo directory: URL) -> some View {
        modifier(TranscriptLinkHandling(directory: directory))
    }
}

private struct TranscriptLinkHandling: ViewModifier {
    let directory: URL
    @State private var file: LocalFileReference?
    @State private var error: String?

    func body(content: Content) -> some View {
        content
            .environment(\.transcriptDirectory, directory)
            .environment(\.openURL, OpenURLAction { url in
                switch TranscriptLink.resolve(url, relativeTo: directory) {
                case let .external(url):
                    return .systemAction(url)
                case let .file(reference):
                    if FileManager.default.fileExists(atPath: reference.url.path) {
                        file = reference
                    } else {
                        error = "The file couldn't be found at \(reference.url.path). "
                            + "It may have been moved or removed."
                    }
                case .unsupported:
                    error = "This link isn't a supported web address or local file: \(url.absoluteString)"
                }
                return .handled
            })
            .sheet(item: $file) { FilePreviewSheet(reference: $0) }
            .alert("Couldn't open link", isPresented: Binding(get: { error != nil }, set: {
                if !$0 {
                    error = nil
                }
            })) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
    }
}
