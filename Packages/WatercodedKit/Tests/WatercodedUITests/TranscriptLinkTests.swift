import Foundation
import Testing
@testable import WatercodedUI

@MainActor
@Suite("Transcript links")
struct TranscriptLinkTests {
    private let directory = URL(filePath: "/tmp/repository", directoryHint: .isDirectory)

    private struct Example: Sendable {
        let source: String
        let expected: LocalFileReference
        init(_ source: String, _ path: String, line: Int? = nil, column: Int? = nil) {
            self.source = source
            expected = LocalFileReference(url: URL(filePath: path), line: line, column: column)
        }
    }

    @Test(arguments: [
        Example(
            "/Users/john/Developer/Watercoded/docs/ARCHITECTURE.md",
            "/Users/john/Developer/Watercoded/docs/ARCHITECTURE.md"
        ),
        Example("docs/My%20Report.md", "/tmp/repository/docs/My Report.md"),
        Example("Sources/App.swift:12:3", "/tmp/repository/Sources/App.swift", line: 12, column: 3),
        Example("README.md:12", "/tmp/repository/README.md", line: 12),
        Example("file:///tmp/code.swift#L12C3", "/tmp/code.swift", line: 12, column: 3),
        Example("./code.swift#L12-L15", "/tmp/repository/code.swift", line: 12),
        Example("file:///tmp/My%20Report.md:12", "/tmp/My Report.md", line: 12),
        Example("../shared/readme.md", "/tmp/shared/readme.md"),
        Example("/tmp/caf%C3%A9%23notes.md", "/tmp/café#notes.md")
    ])
    private func `local links resolve to file URLs without location suffixes`(_ example: Example) throws {
        let url = try #require(URL(string: example.source))
        #expect(TranscriptLink.resolve(url, relativeTo: directory) == .file(example.expected))
    }

    @Test func `real colon filenames and home paths are preserved`() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "watercoded-links-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "report:12")
        try "notes".write(to: file, atomically: true, encoding: .utf8)
        #expect(TranscriptLink.resolve(file, relativeTo: directory) == .file(LocalFileReference(url: file)))
        let home = try #require(URL(string: "~/notes.md"))
        #expect(TranscriptLink.resolve(home, relativeTo: directory)
            ==
            .file(LocalFileReference(url: FileManager.default.homeDirectoryForCurrentUser
                    .appending(path: "notes.md"))))
    }

    @Test(arguments: ["https://example.com/readme#L12", "http://localhost:8080/a?q=b", "mailto:me@example.com"])
    func `web and email destinations remain unchanged`(value: String) throws {
        let url = try #require(URL(string: value))
        #expect(TranscriptLink.resolve(url, relativeTo: directory) == .external(url))
    }

    @Test(arguments: ["javascript:alert(1)", "data:text/html,hello", "unknown:thing", "file://other-host/doc.md"])
    func `unsupported addresses are not passed to Launch Services`(value: String) throws {
        #expect(try TranscriptLink.resolve(#require(URL(string: value)), relativeTo: directory) == .unsupported)
    }

    @Test func `markdown retains links and detects bare URLs without changing code`() throws {
        let linked = MarkdownInline.parse("[Report](/tmp/Report.md:12) https://example.com `https://code.example.com`")
        let links = linked.runs.compactMap(\.link)
        #expect(links.count == 2)
        #expect(try links.contains(#require(URL(string: "/tmp/Report.md:12"))))
        #expect(try links.contains(#require(URL(string: "https://example.com"))))
        #expect(try !links.contains(#require(URL(string: "https://code.example.com"))))
    }

    @Test func `user text stays literal while URLs are actionable`() {
        let text = "**Literal text** and https://example.com"
        let parsed = MarkdownInline.plain(text)
        #expect(String(parsed.characters) == text)
        #expect(parsed.runs.compactMap(\.link).count == 1)
    }

    @Test func `markdown file references become clickable only when present`() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "watercoded-inline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "hello".write(to: folder.appending(path: "app.swift"), atomically: true, encoding: .utf8)
        let parsed = MarkdownInline.parse("See `app.swift:12` and `missing.swift`", directory: folder)
        let link = try #require(parsed.runs.compactMap(\.link).first)
        #expect(parsed.runs.compactMap(\.link).count == 1)
        #expect(TranscriptLink.resolve(link, relativeTo: folder)
            == .file(LocalFileReference(url: folder.appending(path: "app.swift"), line: 12)))
    }

    @Test func `markdown images have an explicit open target`() throws {
        let url = try #require(URL(string: "/tmp/image.png"))
        #expect(MarkdownBlock.parse("![Screenshot](/tmp/image.png)") == [.image(label: "Screenshot", destination: url)])
        #expect(MarkdownBlock.parse("```\n![not an image](x)\n```") == [.code(
            language: nil,
            text: "![not an image](x)"
        )])
    }

    @Test func `documents and images use Quick Look even when their bytes are valid text`() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "watercoded-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["report.md", "source.swift", "document.pdf", "image.svg"] {
            let file = folder.appending(path: name)
            try "ASCII contents".write(to: file, atomically: true, encoding: .utf8)
            #expect((FilePreviewSheet.textContents(of: file) != nil) == ["report.md", "source.swift"].contains(name))
        }
    }
}
