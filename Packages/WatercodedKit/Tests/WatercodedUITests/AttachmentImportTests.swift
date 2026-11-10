import AppKit
import Testing
import UniformTypeIdentifiers
import WatercodedCore
@testable import WatercodedUI

@MainActor
@Suite("Image attachments")
struct AttachmentImportTests {
    @Test func `finder image file drops and image-byte drops both load`() async throws {
        let image = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        for x in 0 ..< 2 {
            for y in 0 ..< 2 {
                image.setColor(.red, atX: x, y: y)
            }
        }
        let png = try #require(image.representation(using: .png, properties: [:]))
        let file = FileManager.default.temporaryDirectory
            .appending(path: "watercoded-attachment-\(UUID().uuidString).png")
        try png.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let finderDrop = NSItemProvider(item: file as NSURL, typeIdentifier: UTType.fileURL.identifier)
        let fromFile = try await AttachmentImport.load(finderDrop)
        #expect(fromFile.filename == file.lastPathComponent)
        #expect(NSImage(data: fromFile.data) != nil)
        let bytesDrop = NSItemProvider()
        bytesDrop.registerDataRepresentation(for: .image, visibility: .all) { completion in
            completion(png, nil)
            return nil
        }
        let fromBytes = try await AttachmentImport.load(bytesDrop)
        #expect(NSImage(data: fromBytes.data) != nil)
    }

    @Test func `non-image files report a failed attachment`() async throws {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "watercoded-not-image-\(UUID().uuidString).txt")
        try "not an image".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let provider = NSItemProvider(item: file as NSURL, typeIdentifier: UTType.fileURL.identifier)
        await #expect(throws: (any Error).self) { try await AttachmentImport.load(provider) }
    }

    @Test func `attachment bytes round trip and older count-only items still load`() throws {
        let image = ImageAttachment(mediaType: "image/png", data: Data([1, 2, 3]), filename: "screen.png")
        let item = TranscriptItem(content: .userImages(count: 1), images: [image])
        let data = try JSONEncoder().encode(item)
        #expect(try JSONDecoder().decode(TranscriptItem.self, from: data) == item)
        var older = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        older.removeValue(forKey: "images")
        let oldData = try JSONSerialization.data(withJSONObject: older)
        let decoded = try JSONDecoder().decode(TranscriptItem.self, from: oldData)
        #expect(decoded.images == nil)
        #expect(decoded.content == .userImages(count: 1))
    }
}
