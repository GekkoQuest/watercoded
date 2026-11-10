import AppKit
import UniformTypeIdentifiers
import WatercodedCore

enum AttachmentImportError: LocalizedError {
    case invalidImage

    var errorDescription: String? {
        "Couldn't attach this file. Choose a smaller image; mention other repository files with @."
    }
}

nonisolated extension ImageAttachment {
    /// Encodes an image for the agent: PNG, or JPEG when PNG would be too large to send.
    init?(image: NSImage, filename: String? = nil) {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        let maximum = 3_500_000
        if let png = bitmap.representation(using: .png, properties: [:]), png.count <= maximum {
            self.init(mediaType: "image/png", data: png, filename: filename)
        } else if let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]),
                  jpeg.count <= maximum {
            self.init(mediaType: "image/jpeg", data: jpeg, filename: filename)
        } else {
            return nil
        }
    }

    init?(fileURL: URL) {
        guard let image = NSImage(contentsOf: fileURL) else { return nil }
        self.init(image: image, filename: fileURL.lastPathComponent)
    }
}

enum AttachmentImport {
    static func load(_ provider: NSItemProvider) async throws -> ImageAttachment {
        // Finder drags usually advertise file URLs, not image bytes. Handle that representation first.
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return try await withCheckedThrowingContinuation { continuation in
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                    let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    guard let url, let image = ImageAttachment(fileURL: url) else {
                        continuation.resume(throwing: error ?? AttachmentImportError.invalidImage)
                        return
                    }
                    continuation.resume(returning: image)
                }
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(for: .image) { data, error in
                guard let data, let image = NSImage(data: data), let attachment = ImageAttachment(image: image) else {
                    continuation.resume(throwing: error ?? AttachmentImportError.invalidImage)
                    return
                }
                continuation.resume(returning: attachment)
            }
        }
    }
}
