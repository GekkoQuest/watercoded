import AppKit
import Foundation
import SwiftUI
import Testing
import WatercodedCore
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
        let host = NSHostingView(rootView: TranscriptView(controller: controller).environment(WindowModel()))
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 900, height: 700),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        window.orderFront(nil)
        controller.handle(.turnStarted)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        for cycle in 0 ..< 24 {
            let button = try #require(findElement(in: host, identifier: "tool-call-\(record.callID)"))
            #expect(button.accessibilityPerformPress())
            for width in [900.0, 500.0, 760.0] {
                window.setContentSize(NSSize(width: width, height: 700))
                controller.streamingText = "Still working. \(cycle) \(width)"
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(40))
            }
            let collapse = try #require(findElement(in: host, identifier: "tool-call-\(record.callID)"))
            #expect(collapse.accessibilityPerformPress())
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
        }
        #expect(controller.transcript.count == items.count)
    }

    private func findElement(in element: any NSAccessibilityProtocol, identifier: String, depth: Int = 0)
        -> (any NSAccessibilityProtocol)? {
        guard depth < 40 else { return nil }
        if element.accessibilityIdentifier() == identifier {
            return element
        }
        for child in element.accessibilityChildren() ?? [] {
            if let child = child as? any NSAccessibilityProtocol,
               let match = findElement(in: child, identifier: identifier, depth: depth + 1) {
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
