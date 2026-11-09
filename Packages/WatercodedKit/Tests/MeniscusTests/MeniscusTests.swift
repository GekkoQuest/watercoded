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
