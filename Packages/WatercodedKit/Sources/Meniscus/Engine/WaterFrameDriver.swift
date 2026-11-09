import AppKit
import QuartzCore
import SwiftUI

/// Hosts the window's display link and watches window motion. Add one per window:
///
/// ```swift
/// RootView().background(WaterFrameDriver(engine: engine))
/// ```
public struct WaterFrameDriver: NSViewRepresentable {
    let engine: WaterEngine

    public init(engine: WaterEngine) {
        self.engine = engine
    }

    public func makeNSView(context: Context) -> WaterFrameDriverView {
        let view = WaterFrameDriverView()
        view.engine = engine
        return view
    }

    public func updateNSView(_ view: WaterFrameDriverView, context: Context) {
        if view.engine !== engine {
            view.engine = engine
        }
    }
}

public final class WaterFrameDriverView: NSView {
    weak var engine: WaterEngine? {
        didSet { engine?.driver = self }
    }

    private var link: CADisplayLink?
    private weak var observedWindow: NSWindow?
    private var preferredFramesPerSecond: Float = 120

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observedWindow {
            NotificationCenter.default.removeObserver(self, name: nil, object: observedWindow)
        }
        link?.invalidate()
        link = nil
        guard let window else { return }

        // NSView.displayLink follows the window across displays, so ProMotion just works.
        let link = displayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = Self.range(preferredFramesPerSecond)
        link.add(to: .main, forMode: .common)
        self.link = link

        let names: [Notification.Name] = [
            NSWindow.willMoveNotification, NSWindow.didMoveNotification,
            NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification,
            NSWindow.didChangeOcclusionStateNotification
        ]
        for name in names {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowChanged(_:)),
                name: name,
                object: window
            )
        }
        observedWindow = window
        engine?.wake()
    }

    @objc private func step(_ link: CADisplayLink) {
        engine?.tick(timestamp: link.timestamp, window: window)
    }

    @objc private func windowChanged(_ notification: Notification) {
        engine?.windowChanged(notification.name, window: window)
    }

    var isPaused: Bool {
        get { link?.isPaused ?? true }
        set { link?.isPaused = newValue }
    }

    func setPreferredFramesPerSecond(_ fps: Float) {
        guard fps != preferredFramesPerSecond else { return }
        preferredFramesPerSecond = fps
        link?.preferredFrameRateRange = Self.range(fps)
    }

    override public func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    private static func range(_ fps: Float) -> CAFrameRateRange {
        CAFrameRateRange(minimum: min(30, fps), maximum: fps, preferred: fps)
    }
}
