import Foundation
import simd
import Testing
@testable import Meniscus

@Suite("Water physics")
struct WaterSurfaceTests {
    private func makeSurface(level: Float = 0.5) -> WaterSurface {
        let surface = WaterSurface(columns: 120, level: level)
        surface.resize(to: [600, 400])
        surface.snapToRest()
        return surface
    }

    @Test func `layout does not disturb resting water`() {
        let surface = WaterSurface(columns: 20, level: 0.5)
        surface.resize(to: [18, 26])
        surface.step(dt: 1.0 / 60, accel: .zero, gain: 1, turbulence: 0, bubbleRate: 0)
        #expect(surface.isSettled)
        surface.resize(to: [22, 30])
        #expect(surface.isSettled)
    }

    @Test func `streaming ripples agree across display refresh rates`() {
        func simulate(fps: Int) -> [Float] {
            let surface = makeSurface()
            for _ in 0 ..< fps * 6 {
                surface.step(dt: 1 / Float(fps), accel: .zero, gain: 1, turbulence: 1, bubbleRate: 0)
            }
            return surface.heights
        }
        let slow = simulate(fps: 30)
        let fast = simulate(fps: 120)
        #expect(fast.contains { abs($0) > 0.1 }, "Streaming must remain visible")
        for (lhs, rhs) in zip(slow, fast) {
            #expect(abs(lhs - rhs) < 0.25, "Low Power Mode should retain the same motion")
        }
    }

    @Test func `drop splashes then settles`() {
        let surface = makeSurface()
        surface.drop(radius: 6)
        #expect(!surface.isSettled)

        var splashed = false
        for _ in 0 ..< 120 * 8 {
            surface.step(dt: 1.0 / 120, accel: .zero, gain: 1, turbulence: 0, bubbleRate: 0)
            splashed = splashed || surface.energy > 0.05
            if surface.isSettled {
                break
            }
        }
        #expect(splashed)
        #expect(surface.isSettled, "water should come to rest within eight seconds")
    }

    @Test func `sloshing conserves volume`() {
        let surface = makeSurface()
        for frame in 0 ..< 240 {
            let push: Float = frame < 30 ? 8000 : 0
            surface.step(dt: 1.0 / 120, accel: [push, 0], gain: 1, turbulence: 0, bubbleRate: 0)
            let mean = surface.heights.reduce(0, +) / Float(surface.heights.count)
            #expect(abs(mean) < 0.001)
        }
        // Accelerating right piles water up on the left.
        #expect(surface.energy > 0)
    }

    @Test func `level eases to target`() {
        let surface = makeSurface(level: 0.2)
        surface.targetLevel = 0.8
        for _ in 0 ..< 240 {
            surface.step(dt: 1.0 / 120, accel: .zero, gain: 1, turbulence: 0, bubbleRate: 0)
        }
        #expect(abs(surface.level - 0.8) < 0.01)
    }

    @Test func `approval droplet hangs and falls`() {
        let surface = makeSurface()
        surface.beginHang()
        for _ in 0 ..< 60 {
            surface.step(dt: 1.0 / 120, accel: .zero, gain: 1, turbulence: 0, bubbleRate: 0)
        }
        #expect(surface.packedHang().z > 4)
        surface.releaseHang()
        #expect(surface.packedHang() == .zero)
        #expect(surface.particles.count == 1)
    }

    @Test func `still mode has no waves`() {
        let surface = makeSurface()
        surface.drop(radius: 6)
        surface.stepStill(dt: 1.0 / 60)
        #expect(surface.particles.isEmpty)
        #expect(surface.energy == 0)
    }
}

@Suite("Shake detection")
struct MotionTrackerTests {
    @Test func `side to side shake is vigorous then violent`() {
        var tracker = MotionTracker()
        var peak = ShakeLevel.none
        var reachedVigorousAt: Double?
        let dt = 1.0 / 120
        for frame in 0 ..< Int(2.6 / dt) {
            let t = Double(frame) * dt
            let x = sin(t * 4.5 * 2 * .pi) * 50
            let level = tracker.update(position: [x, 0], dt: dt, now: t).level
            if level >= .vigorous, reachedVigorousAt == nil {
                reachedVigorousAt = t
            }
            peak = max(peak, level)
        }
        #expect(peak == .violent)
        #expect((reachedVigorousAt ?? 99) < 0.6)
    }

    @Test func `slow drag is only gentle`() {
        var tracker = MotionTracker()
        var peak = ShakeLevel.none
        let dt = 1.0 / 120
        for frame in 0 ..< 240 {
            let t = Double(frame) * dt
            peak = max(peak, tracker.update(position: [t * 200, 0], dt: dt, now: t).level)
        }
        #expect(peak == .gentle)
    }
}

@Suite("Water accessibility")
@MainActor
struct VesselAccessibilityTests {
    @Test func `reduce motion can settle while streaming and delegating`() {
        let engine = WaterEngine()
        engine.reduceMotion = true
        let vessel = engine.vessel(
            for: "active",
            initial: WaterState(level: 0.5, isStreaming: true, hasSubagents: true)
        )
        vessel.perform(.drop(.large))
        vessel.step(dt: 1.0 / 60, accel: [8000, 0], gain: 0, still: true, time: 5)
        #expect(vessel.isSettled)
        let frame = vessel.frame(for: .panel)
        #expect(frame.heights.allSatisfy { $0 == 0 })
        #expect(frame.time == 0)
        engine.reduceMotion = false
        #expect(!vessel.isSettled)
    }
}
