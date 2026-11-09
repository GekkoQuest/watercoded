import Observation
import simd
import SwiftUI

/// The size class a vessel is drawn at. Each gets its own simulation so physics stays
/// correct in points at every scale.
public enum VesselRole: Hashable, Sendable, CaseIterable {
    /// Sidebar / list glyph.
    case glyph
    /// The wide, short vessel behind a Current's composer.
    case panel

    var columns: Int {
        switch self {
        case .glyph: 20
        case .panel: 120
        }
    }

    var particleCap: Int {
        switch self {
        case .glyph: 10
        case .panel: 48
        }
    }

    var dropScale: Float {
        switch self {
        case .glyph: 0.45
        case .panel: 1
        }
    }
}

/// Everything the shader needs for one frame.
struct RenderFrame: Equatable {
    var heights: [Float]
    var particles: [Float] = [0, 0, 0, -1]
    var hang: SIMD4<Float> = .zero
    var level: Float
    var clarity: Float = 1
    var frost: Float = 0
    var heat: Float = 0
    var time: Float = 0
}

/// One body of water, shown at one or more ``VesselRole``s.
@MainActor
@Observable
public final class Vessel {
    public private(set) var state: WaterState
    private(set) var frames: [VesselRole: RenderFrame]

    @ObservationIgnored private var surfaces: [VesselRole: WaterSurface]
    @ObservationIgnored private var clarity: Float = 1
    @ObservationIgnored private var frost: Float = 0
    @ObservationIgnored private var heat: Float = 0
    @ObservationIgnored private var hasStepped = false
    @ObservationIgnored private var publishedAtRest = false
    /// Set when an approval disappears; evaporates the droplet unless an explicit impulse lands first.
    @ObservationIgnored private var resolveHangOnNextStep = false
    @ObservationIgnored weak var engine: WaterEngine?

    init(state: WaterState) {
        self.state = state
        var surfaces: [VesselRole: WaterSurface] = [:]
        var frames: [VesselRole: RenderFrame] = [:]
        for role in VesselRole.allCases {
            var tuning = WaterSurface.Tuning()
            tuning.particleCap = role.particleCap
            surfaces[role] = WaterSurface(columns: role.columns, level: Float(state.level), tuning: tuning)
            frames[role] = RenderFrame(heights: Array(repeating: 0, count: role.columns), level: Float(state.level))
        }
        self.surfaces = surfaces
        self.frames = frames
    }

    /// Updates what the water represents. Cheap to call often; only changes take effect.
    public func apply(_ newState: WaterState) {
        guard newState != state else { return }
        let old = state
        state = newState
        for surface in surfaces.values {
            surface.targetLevel = Float(min(1, max(0, newState.level)))
            if newState.isAwaitingApproval, !old.isAwaitingApproval {
                surface.beginHang()
            }
        }
        if old.isAwaitingApproval, !newState.isAwaitingApproval {
            resolveHangOnNextStep = true
        }
        wake()
    }

    /// Applies a one-off disturbance.
    public func perform(_ impulse: WaterImpulse) {
        if case .approvalGranted = impulse {
            resolveHangOnNextStep = false
        }
        if case .approvalDenied = impulse {
            resolveHangOnNextStep = false
        }
        for (role, surface) in surfaces {
            switch impulse {
            case let .drop(size): if !state.isFrozen {
                    surface.drop(radius: size.radius * role.dropScale)
                }
            case .approvalGranted: surface.releaseHang()
            case .approvalDenied: surface.evaporateHang()
            case .drained: surface.gurgle()
            case .calm: surface.calm()
            }
        }
        wake()
    }

    func frame(for role: VesselRole) -> RenderFrame {
        frames[role] ?? RenderFrame(heights: [0, 0, 0, 0], level: Float(state.level))
    }

    func resize(_ role: VesselRole, to size: CGSize) {
        surfaces[role]?.resize(to: SIMD2(Float(size.width), Float(size.height)))
        publishedAtRest = false
        wake()
    }

    private func wake() {
        engine?.wake()
    }

    // MARK: Stepping (driven by WaterEngine)

    var surfaceForHaptics: WaterSurface? {
        surfaces[.panel]
    }

    func step(dt: Float, accel: SIMD2<Float>, gain: Float, still: Bool, time: Double) {
        let clarityTarget: Float = state.isHealthy ? 1 : 0.12
        let frostTarget: Float = state.isFrozen ? 1 : (state.isChilled ? 0.3 : 0)
        let heatTarget = Float(min(1, max(0, state.heat)))
        if !hasStepped {
            clarity = clarityTarget
            frost = frostTarget
            heat = heatTarget
            hasStepped = true
        }
        if resolveHangOnNextStep {
            resolveHangOnNextStep = false
            surfaces.values.forEach { $0.evaporateHang() }
        }
        clarity = Self.approach(clarity, clarityTarget, rate: 1.6, dt: dt)
        frost = Self.approach(frost, frostTarget, rate: 2.5, dt: dt)
        heat = Self.approach(heat, heatTarget, rate: 1.5, dt: dt)

        for (role, surface) in surfaces {
            if still {
                surface.stepStill(dt: dt)
            } else if !state.isFrozen {
                surface.step(
                    dt: dt,
                    accel: accel,
                    gain: gain,
                    turbulence: state.isStreaming ? (role == .glyph ? 0.35 : 1) : 0,
                    bubbleRate: state.hasSubagents ? (role == .glyph ? 2 : 7) : 0
                )
            }
        }

        let atRest = isSettled
        if atRest {
            surfaces.values.forEach { $0.snapToRest() }
            if publishedAtRest {
                return
            } // nothing changed since the last published frame
            publishedAtRest = true
        } else {
            publishedAtRest = false
        }

        let frameTime = atRest ? (frames[.panel]?.time ?? 0) : Float(time.truncatingRemainder(dividingBy: 1000))
        var newFrames: [VesselRole: RenderFrame] = [:]
        for (role, surface) in surfaces {
            newFrames[role] = RenderFrame(
                heights: surface.heights,
                particles: surface.packedParticles(),
                hang: surface.packedHang(),
                level: surface.level,
                clarity: clarity,
                frost: frost,
                heat: heat,
                time: frameTime
            )
        }
        frames = newFrames
    }

    var isSettled: Bool {
        !state.isStreaming && !state.hasSubagents
            && (state.isFrozen || surfaces.values.allSatisfy(\.isSettled))
            && clarity == (state.isHealthy ? 1 : 0.12)
            && frost == (state.isFrozen ? 1 : (state.isChilled ? 0.3 : 0))
            && heat == Float(min(1, max(0, state.heat)))
    }

    private static func approach(_ value: Float, _ target: Float, rate: Float, dt: Float) -> Float {
        let next = value + (target - value) * min(1, dt * rate)
        return abs(target - next) < 0.002 ? target : next
    }
}
