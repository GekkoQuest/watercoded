import CryptoKit
import Foundation
import WatercodedCore

/// Disk-only records keep image bytes out of transcript rewrites. Domain values still own their
/// attachments, so exports, branching and existing embedded-image transcripts retain their behavior.
struct TranscriptStorage {
    private var cachedImages: [UUID: (data: Data, digest: String)] = [:]
    private struct Archive: Codable {
        var schemaVersion = 1
        var value: [Entry]
    }

    private struct Entry: Codable {
        var item: TranscriptItem
        var attachments: [Attachment]?
    }

    private struct Attachment: Codable {
        var id: UUID
        var mediaType: String
        var filename: String?
        var digest: String
    }

    mutating func save(_ transcript: [TranscriptItem], to url: URL, directory: URL) throws {
        let retainedIDs = Set(transcript.flatMap { $0.images?.map(\.id) ?? [] })
        cachedImages = cachedImages.filter { retainedIDs.contains($0.key) }
        let images = directory.appending(path: "attachments")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let entries = try transcript.map { item in
            var entry = Entry(item: item)
            entry.attachments = try item.images?.map { image in
                let digest: String
                if let cached = cachedImages[image.id], cached.data == image.data {
                    digest = cached.digest
                } else {
                    digest = SHA256.hash(data: image.data).map { String(format: "%02x", $0) }.joined()
                    cachedImages[image.id] = (image.data, digest)
                }
                let file = images.appending(path: digest)
                if !FileManager.default.fileExists(atPath: file.path) {
                    try image.data.write(to: file, options: .atomic)
                }
                return Attachment(id: image.id, mediaType: image.mediaType, filename: image.filename, digest: digest)
            }
            entry.item.images = nil
            return entry
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Archive(value: entries)).write(to: url, options: .atomic)
    }

    static func load(from url: URL, directory: URL) throws -> [TranscriptItem] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(Archive.self, from: Data(contentsOf: url))
        guard archive.schemaVersion == 1 else { throw CocoaError(.fileReadCorruptFile) }
        return try archive.value.map { entry in
            var item = entry.item
            item.images = try entry.attachments?.map { attachment in
                guard attachment.digest.count == 64, attachment.digest.allSatisfy(\.isHexDigit) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let data = try Data(contentsOf: directory.appending(path: "attachments/\(attachment.digest)"))
                var image = ImageAttachment(mediaType: attachment.mediaType, data: data, filename: attachment.filename)
                image.id = attachment.id
                return image
            }
            return item
        }
    }
}
