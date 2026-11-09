import AppKit
import Observation
import simd
import SwiftUI

/// Drives every ``Vessel`` from one display link: reads window motion, steps the physics,
/// plays haptics, reports shakes, and sleeps whenever nothing is moving.
///
/// Attach exactly one ``WaterFrameDriver`` per window (e.g. as a background of the root view).
@MainActor
@Observable
public final class WaterEngine {
    // MARK: Settings

    public var intensity: PhysicsIntensity = .lively {
        didSet { wake() }
    }

    public var reduceMotion = false {
        didSet { wake() }
    }

    public var hapticsEnabled = true

    // MARK: Status

    public private(set) var isAwake = false
    public private(set) var shakeLevel: ShakeLevel = .none
    public private(set) var framesPerSecond = 0

    /// Called when the shake level rises to `.vigorous` or `.violent`.
    @ObservationIgnored public var onShake: (@MainActor (ShakeLevel) -> Void)?

    @ObservationIgnored private var vessels: [AnyHashable: Vessel] = [:]
    @ObservationIgnored weak var driver: WaterFrameDriverView?
    @ObservationIgnored private var tracker = MotionTracker()
    @ObservationIgnored private var lastTimestamp: CFTimeInterval?
    @ObservationIgnored private var time: Double = 0
    @ObservationIgnored private var quietTime: Double = 0
    @ObservationIgnored private var frameCount = 0
    @ObservationIgnored private var fpsWindowStart: Double = 0
    @ObservationIgnored private var lastHaptic: Double = 0
    @ObservationIgnored private var occluded = false
    @ObservationIgnored private var keepAwakeUntil: Double = 0

    public init() {}

    // MARK: Vessels

    /// The vessel for `key`, created on first use.
    public func vessel(for key: some Hashable, initial: WaterState = WaterState()) -> Vessel {
        let key = AnyHashable(key)
        if let vessel = vessels[key] {
            return vessel
        }
        let vessel = Vessel(state: initial)
        vessel.engine = self
        vessels[key] = vessel
        wake()
        return vessel
    }

    public func removeVessel(for key: some Hashable) {
        vessels[AnyHashable(key)] = nil
    }

    /// The vessel whose impacts produce haptics (usually the one in focus).
    @ObservationIgnored public var hapticVesselKey: AnyHashable?

    // MARK: Frame loop

    func tick(timestamp: CFTimeInterval, window: NSWindow?) {
        let dt = lastTimestamp.map { min(max(timestamp - $0, 1.0 / 240), 1.0 / 30) } ?? (1.0 / 120)
        lastTimestamp = timestamp
        time += dt
        countFrame()

        var reading = MotionTracker.Reading.still
        if let window {
            let origin = window.frame.origin
            reading = tracker.update(position: SIMD2(Double(origin.x), Double(origin.y)), dt: dt, now: time)
        }
        // AppKit is y-up; vessel space is y-down.
        let accel = SIMD2(Float(reading.acceleration.x), Float(-reading.acceleration.y))
        report(reading.level)

        let still = reduceMotion || intensity == .still
        let gain = still ? 0 : intensity.gain
        for vessel in vessels.values {
            vessel.step(dt: Float(dt), accel: accel, gain: gain, still: still, time: time)
        }
        playHaptics(gain: gain, still: still)

        let quiet = tracker.isStill(now: time) && time > keepAwakeUntil && vessels.values.allSatisfy(\.isSettled)
        quietTime = quiet ? quietTime + dt : 0
        if quietTime > 0.3 {
            sleep()
        }
    }

    func windowChanged(_ name: Notification.Name, window: NSWindow?) {
        if name == NSWindow.didChangeOcclusionStateNotification {
            occluded = !(window?.occlusionState.contains(.visible) ?? true)
            if occluded {
                sleep()
            } else {
                wake()
            }
        } else {
            wake()
        }
    }

    /// Resumes the display link. Called automatically by vessels and window events.
    public func wake(for duration: Double = 0) {
        keepAwakeUntil = max(keepAwakeUntil, time + duration)
        guard !occluded, let driver else { return }
        applyPowerPolicy()
        if driver.isPaused || !isAwake {
            driver.isPaused = false
            isAwake = true
            quietTime = 0
        }
    }

    private func sleep() {
        guard isAwake else { return }
        driver?.isPaused = true
        isAwake = false
        lastTimestamp = nil
        tracker.reset()
        shakeLevel = .none
    }

    private func countFrame() {
        frameCount += 1
        if time - fpsWindowStart >= 1 {
            framesPerSecond = frameCount
            frameCount = 0
            fpsWindowStart = time
        }
    }

    private func report(_ level: ShakeLevel) {
        guard level != shakeLevel else { return }
        let rising = level > shakeLevel
        shakeLevel = level
        guard rising, level >= .vigorous, !reduceMotion else { return }
        if hapticsEnabled {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        onShake?(level)
    }

    private func playHaptics(gain: Float, still: Bool) {
        guard hapticsEnabled, !still, time - lastHaptic > 0.18,
              let key = hapticVesselKey, let surface = vessels[key]?.surfaceForHaptics
        else { return }
        if surface.wallImpact > 260 / max(gain, 0.5) || surface.biggestSplash > 70 {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            lastHaptic = time
        }
    }

    /// 30 fps in Low Power Mode or under thermal pressure; otherwise up to 120.
    private func applyPowerPolicy() {
        let info = ProcessInfo.processInfo
        let constrained = info.isLowPowerModeEnabled || info.thermalState == .serious || info.thermalState == .critical
        driver?.setPreferredFramesPerSecond(constrained ? 30 : 120)
    }
}
