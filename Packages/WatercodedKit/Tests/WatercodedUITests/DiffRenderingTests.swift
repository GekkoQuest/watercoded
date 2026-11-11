import AppKit
import Darwin
import Foundation
import SwiftUI
import Testing
@testable import GitKit
@testable import WatercodedUI

@MainActor
@Suite("Large diff rendering", .serialized, .timeLimit(.minutes(1)))
struct DiffRenderingTests {
    @Test func `large files mount visible lines instead of the entire patch`() async throws {
        let file = largeFile()
        let rows = DiffFileLayout(file: file).rows
        #expect(rows.count == 20001)
        #expect(rows.first == DiffFileLayout.Row(hunk: 0, line: nil))
        #expect(rows.last == DiffFileLayout.Row(hunk: 0, line: 19999))

        let watchdog = diffMemoryWatchdog()
        defer { watchdog.cancel() }
        let host = NSHostingView(rootView: DiffFileContentView(file: file, canRevert: false))
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 430, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        window.orderFront(nil)
        for width in [430.0, 900.0, 500.0] {
            window.setContentSize(NSSize(width: width, height: 600))
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            #expect(countViews(host) < 250, "A large patch must not create a native view for every source line")
        }
        let scroll = try #require(findScrollView(host))
        let document = try #require(scroll.documentView)
        #expect(document.bounds.height > scroll.documentVisibleRect.height)
        // Exercise recycling at the far end of the file as well as at its start.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.maxY - scroll.contentView.bounds.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        #expect(countViews(host) < 250)
    }

    private func largeFile() -> FileDiff {
        FileDiff(path: "generated.json", change: .added, isBinary: false, hunks: [
            Hunk(header: "@@ -0,0 +1,20000 @@", lines: (0 ..< 20000).map {
                DiffLine(kind: .addition, text: "  value: \($0),", newNumber: $0 + 1)
            })
        ])
    }

    private func countViews(_ view: NSView) -> Int {
        1 + view.subviews.reduce(0) { $0 + countViews($1) }
    }

    private func findScrollView(_ view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView {
            return scroll
        }
        return view.subviews.lazy.compactMap { findScrollView($0) }.first
    }
}

/// Stops even a blocked main thread if a future regression reintroduces eager allocation.
private func diffMemoryWatchdog() -> any DispatchSourceTimer {
    let timer = DispatchSource.makeTimerSource(queue: .global())
    timer.schedule(deadline: .now(), repeating: .milliseconds(100))
    timer.setEventHandler {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS, info.phys_footprint > 700_000_000 {
            FileHandle.standardError.write(Data("Large diff exceeded the test memory cutoff.\n".utf8))
            _exit(86)
        }
    }
    timer.resume()
    return timer
}
