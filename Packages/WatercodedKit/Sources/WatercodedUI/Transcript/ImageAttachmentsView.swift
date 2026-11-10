import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WatercodedCore
import WatercodedDesign

/// The same image interactions are available before sending and in the saved transcript.
struct ImageAttachmentsView: View {
    let images: [ImageAttachment]
    var remove: ((UUID) -> Void)?
    @State private var selected: ImageAttachment?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Spacing.small) {
                ForEach(images) { attachment in
                    Button { selected = attachment } label: {
                        if let image = NSImage(data: attachment.data) {
                            Image(nsImage: image).resizable().scaledToFill()
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: Radius.small))
                        } else {
                            Label("Image unavailable", systemImage: "photo").frame(width: 100, height: 64)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Preview \(attachment.filename ?? "image")")
                    .accessibilityLabel("Preview \(attachment.filename ?? "attached image")")
                    .overlay(alignment: .topTrailing) {
                        if let remove {
                            Button("Remove image", systemImage: "xmark.circle.fill") { remove(attachment.id) }
                                .labelStyle(.iconOnly).buttonStyle(.plain)
                                .foregroundStyle(.white, .black.opacity(0.6))
                        }
                    }
                }
            }
            .padding(Spacing.xxSmall)
        }
        .scrollIndicators(.never)
        .frame(height: 72)
        .sheet(item: $selected) { ImageAttachmentPreview(attachment: $0) }
    }
}

private struct ImageAttachmentPreview: View {
    let attachment: ImageAttachment
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        VStack(spacing: Spacing.medium) {
            HStack {
                Text(attachment.filename ?? "Attached image").font(.headline).textSelection(.enabled)
                Spacer()
                Button("Copy image", systemImage: "doc.on.doc") {
                    guard let image = NSImage(data: attachment.data) else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([image])
                }
                Button("Save image…", systemImage: "square.and.arrow.down", action: save)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let image = NSImage(data: attachment.data) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Image unavailable", systemImage: "photo")
            }
            if let error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .padding(Spacing.large)
        .frame(minWidth: 560, idealWidth: 800, minHeight: 400, idealHeight: 600)
    }

    private func save() {
        let panel = NSSavePanel()
        let type = UTType(mimeType: attachment.mediaType) ?? .png
        panel.allowedContentTypes = [type]
        let stem = ((attachment.filename ?? "Image") as NSString).deletingPathExtension
        panel.nameFieldStringValue = stem + "." + (type.preferredFilenameExtension ?? "png")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try attachment.data.write(to: url, options: .atomic)
            error = nil
        } catch { self.error = "Couldn't save the image: \(error.localizedDescription)" }
    }
}
