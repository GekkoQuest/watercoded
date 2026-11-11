import AppKit
import Foundation
import SwiftUI
import Testing
import WatercodedCore
import WatercodedDesign
@testable import Orchestrator
@testable import WatercodedUI

@MainActor
@Suite("Tool expansion in a live transcript", .serialized, .timeLimit(.minutes(1)))
struct ToolExpansionTests {
    @Test func `expand and collapse a shell command while output streams and width changes`() async throws {
        let record = ToolCallRecord(
            callID: "expansion-regression", name: "Shell", kind: .shell,
            summary: "Inspect generated data", input: Self.command,
            output: Self.output, status: .succeeded
        )
        var items = (0 ..< 300).map { index in
            TranscriptItem(content: .assistant(text: "Progress \(index). " + String(
                repeating: "Wrapping text. ",
                count: 30
            )))
        }
        items.append(TranscriptItem(content: .toolCall(record)))
        let controller = CurrentController(
            current: Current(
                poolID: PoolID(),
                title: "Expansion",
                providerID: "test",
                channel: Channel(kind: .checkout, path: "/tmp", branch: "main", baseCommit: "HEAD")
            ),
            transcript: items, provider: nil, repository: InMemoryWorkspaceRepository()
        )
        defer { controller.discard() }
        let model = WindowModel()
        model.highlightedItem = items[items.count - 1].id
        let host = NSHostingView(rootView: TranscriptView(controller: controller).environment(model))
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 900, height: 700),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        controller.handle(.turnStarted)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        for cycle in 0 ..< 24 {
            FileHandle.standardError.write(Data("Expanding command, cycle \(cycle)\n".utf8))
            let button = try #require(findElement(in: window, identifier: "tool-call-\(record.callID)"))
            #expect((button.accessibilityPerformPress?() ?? false))
            for width in [900.0, 500.0, 760.0] {
                window.setContentSize(NSSize(width: width, height: 700))
                controller.streamingText = "Still working. \(cycle) \(width)"
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(40))
            }
            let collapse = try #require(findElement(in: window, identifier: "tool-call-\(record.callID)"))
            #expect((collapse.accessibilityPerformPress?() ?? false))
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
        }
        #expect(controller.transcript.count == items.count)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WATERCODED_LEGACY_RENDERER"] != "1"))
    func `code viewport stays bounded while wrapped output changes and selection survives`() async throws {
        let text = Self.output + "\nUnicode: 🌊"
        let host = NSHostingView(rootView: ToolCodeBlock(title: "Output", text: text))
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 900, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let editor = try #require(findEditor(in: host))
        let scroll = try #require(editor.enclosingScrollView)
        let selection = (text as NSString).range(of: "Unicode: 🌊")
        editor.setSelectedRange(selection)
        for width in [900.0, 280.0, 760.0, 400.0] {
            window.setContentSize(NSSize(width: width, height: 600))
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            #expect(scroll.frame.height > 0 && scroll.frame.height <= Metrics.toolPreviewMaxHeight + 1)
            #expect(editor.string == text)
            #expect(editor.selectedRange() == selection)
            #expect(editor.isSelectable && !editor.isEditable)
        }
        host.rootView = ToolCodeBlock(title: "Output", text: text + "\nNew output")
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        #expect(editor.string.hasSuffix("New output"))
        #expect(editor.selectedRange() == selection)
        #expect(editor.bounds.height > scroll.documentVisibleRect.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: editor.bounds.maxY - scroll.contentView.bounds.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(scroll.documentVisibleRect.maxY <= editor.bounds.maxY + 1)
    }

    private func findEditor(in view: NSView) -> NSTextView? {
        if let editor = view as? NSTextView {
            return editor
        }
        return view.subviews.lazy.compactMap { findEditor(in: $0) }.first
    }

    private func findElement(in element: AnyObject, identifier: String, depth: Int = 0)
        -> (AnyObject)? {
        guard depth < 40 else { return nil }
        if element.accessibilityIdentifier?() == identifier {
            return element
        }
        for child in element.accessibilityChildren?() ?? [] {
            if let match = findElement(in: child as AnyObject, identifier: identifier, depth: depth + 1) {
                return match
            }
        }
        return nil
    }

    private static let command = JSONValue.object(["command": .string("""
    sed -n '176,195p' tools/import_data.py
    sed -n '214,230p' tools/reconstruct_data.py
    python3 - <<'PY'
    from pathlib import Path
    root = Path('client/manifest')
    print(root)
    print([name for name in ['first', 'second', 'third']])
    PY
    """)]).compactString()
    private static let output = (0 ..< 40).map { index in
        "    field_\(index) = '" + String(repeating: "x", count: index == 20 ? 320 : 48) + "'"
    }.joined(separator: "\n")
}
