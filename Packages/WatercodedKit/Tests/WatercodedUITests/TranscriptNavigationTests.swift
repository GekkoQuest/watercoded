import AppKit
import Foundation
import SwiftUI
import Testing
import WatercodedCore
@testable import Orchestrator
@testable import WatercodedUI

@MainActor
@Suite("Transcript navigation", .serialized, .timeLimit(.minutes(1)))
struct TranscriptNavigationTests {
    @Test func `question navigation is consumed and resizing keeps the viewport inside the chat`() async throws {
        var items = (0 ..< 100).map { index in
            TranscriptItem(content: .assistant(text: "Message \(index). " + String(
                repeating: "Progress update. ",
                count: 20
            )))
        }
        items[10].content = .question(QuestionRecord(
            requestID: "old-question", questions: [.init(text: "Which option?", options: [])], isAsynchronous: true
        ))
        let controller = CurrentController(
            current: Current(
                poolID: PoolID(),
                title: "Navigation",
                providerID: "test",
                channel: Channel(kind: .checkout, path: "/tmp", branch: "main", baseCommit: "HEAD")
            ),
            transcript: items, provider: nil, repository: InMemoryWorkspaceRepository()
        )
        defer { controller.discard() }
        let model = WindowModel()
        model.highlightedItem = items[10].id
        let host =
            NSHostingView(rootView: AnyView(TranscriptView(controller: controller).environment(model).id(UUID())))
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 900, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        #expect(model.highlightedItem == nil, "The request must not survive reopening the session")

        // Recreate the session view as switching away and back would do.
        host.rootView = AnyView(TranscriptView(controller: controller).environment(model).id(UUID()))
        for width in [430.0, 900.0, 500.0] {
            window.setContentSize(NSSize(width: width, height: 600))
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(500))
            let scroll = try #require(findScrollView(in: host))
            let document = try #require(scroll.documentView)
            let visible = scroll.documentVisibleRect
            #expect(visible.intersects(document.bounds))
            #expect(
                visible.maxY <= document.bounds.maxY + 1,
                "Opening the inspector must not leave the viewport below the transcript"
            )
            #expect(
                document.bounds.maxY - visible.maxY < 80,
                "Reopening and resizing should follow the latest progress, not the old question"
            )
        }
    }

    private func findScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView {
            return scroll
        }
        return view.subviews.lazy.compactMap { findScrollView(in: $0) }.first
    }
}
