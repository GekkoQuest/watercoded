import Foundation
import simd

/// A droplet, spray fleck or bubble, in vessel space (points, y grows downward).
struct WaterParticle {
    enum Kind: Float {
        case drop = 0
        case bubble = 1
    }

    var position: SIMD2<Float>
    var velocity: SIMD2<Float>
    var radius: Float
    var kind: Kind
    var age: Float = 0
    var seed: Float = .random(in: 0 ... 6.28)
}

/// A side-view body of water: a row of columns obeying a damped wave equation, free particles
/// (drops, spray, bubbles) and an optional hanging droplet.
///
/// Conventions: `heights` are displacements in points, positive = up. Vessel space has
/// y = 0 at the rim, growing downward. The fill `level` is authoritative: waves only
/// redistribute water, so the level always shows the true value it represents.
final class WaterSurface {
    struct Tuning {
        var waveSpeed: Float = 340
        var damping: Float = 1.15
        var restoring: Float = 1.6
        var tiltGain: Float = 0.55
        var sprayThreshold: Float = 230
        var gravity: Float = 1900
        var particleCap = 48
    }

    enum HangState {
        case none
        case hanging(since: Date)
        case evaporating
    }

    let columns: Int
    var tuning: Tuning
    private(set) var heights: [Float]
    private var velocities: [Float]
    private(set) var particles: [WaterParticle] = []
    private(set) var size: SIMD2<Float> = [400, 300]

    private(set) var level: Float
    private var levelVelocity: Float = 0
    var targetLevel: Float

    private(set) var hangState: HangState = .none
    private(set) var hangRadius: Float = 0
    private var hangOffset: SIMD2<Float> = .zero
    private var hangOffsetVelocity: SIMD2<Float> = .zero
    private var extraDamping: Float = 0

    /// Strongest edge-column speed in the last step (drives "wall slam" haptics).
    private(set) var wallImpact: Float = 0
    /// Largest drop impact in the last step.
    private(set) var biggestSplash: Float = 0

    init(columns: Int, level: Float, tuning: Tuning = Tuning()) {
        precondition(columns >= 4, "A surface needs at least four columns")
        self.columns = columns
        self.tuning = tuning
        heights = Array(repeating: 0, count: columns)
        velocities = Array(repeating: 0, count: columns)
        self.level = level
        targetLevel = level
    }

    // MARK: Geometry

    func resize(to newSize: SIMD2<Float>) {
        guard newSize.x > 4, newSize.y > 4 else { return }
        let delta = (newSize.x - size.x) * 0.02
        size = newSize
        if abs(delta) > 0.1 {
            impulse(atX: newSize.x * 0.5, strength: min(abs(delta), 40), width: 12)
        }
    }

    func surfaceY(atX x: Float) -> Float {
        let position = max(0, min(1, x / size.x)) * Float(columns - 1)
        let lower = Int(position)
        let upper = min(lower + 1, columns - 1)
        let t = position - Float(lower)
        let height = heights[lower] * (1 - t) + heights[upper] * t
        return size.y * (1 - level) - height
    }

    /// Size factor for drops, spray and the hanging droplet. Narrow or short vessels get smaller ones.
    private var scale: Float {
        min(1, size.x / 260 + 0.25, size.y / 110 + 0.2)
    }

    var hangCenter: SIMD2<Float> {
        SIMD2(size.x * 0.5 + hangOffset.x, 4 + hangRadius * 1.15 + hangOffset.y)
    }

    // MARK: Events

    /// A drop falls in from above at a random point.
    func drop(radius: Float) {
        guard particles.count < tuning.particleCap else { return }
        let x = Float.random(in: 0.15 ... 0.85) * size.x
        let r = radius * scale
        particles.append(WaterParticle(
            position: [x, -r],
            velocity: [.random(in: -20 ... 20), 140],
            radius: r,
            kind: .drop
        ))
    }

    func spawnBubble() {
        guard particles.count < tuning.particleCap else { return }
        let x = Float.random(in: 0.08 ... 0.92) * size.x
        particles.append(WaterParticle(
            position: [x, size.y - 3],
            velocity: [0, -20],
            radius: .random(in: 1.8 ... 4.5) * min(1, size.x / 200 + 0.4),
            kind: .bubble
        ))
    }

    func beginHang() {
        if case .hanging = hangState {
            return
        }
        hangState = .hanging(since: .now)
        if hangRadius < 1 {
            hangRadius = 2
        }
    }

    /// Approve: the droplet lets go and falls in.
    func releaseHang() {
        guard case .hanging = hangState else { return }
        if particles.count < tuning.particleCap {
            particles.append(WaterParticle(
                position: hangCenter,
                velocity: [hangOffsetVelocity.x * 0.2, 60],
                radius: hangRadius,
                kind: .drop
            ))
        }
        hangState = .none
        hangRadius = 0
    }

    /// Deny: the droplet evaporates.
    func evaporateHang() {
        guard case .hanging = hangState else { return }
        hangState = .evaporating
    }

    /// Calms the water quickly for a moment (used when the user settles an agent).
    func calm() {
        extraDamping = 6
    }

    /// Compaction: a gurgle of bubbles as the level drops.
    func gurgle() {
        for _ in 0 ..< 8 {
            spawnBubble()
        }
    }

    private func impulse(atX x: Float, strength: Float, width: Float) {
        let center = x / size.x * Float(columns - 1)
        let span = Int(width.rounded(.up))
        let lower = max(0, Int(center) - span)
        let upper = min(columns - 1, Int(center) + span)
        guard lower <= upper else { return }
        for index in lower ... upper {
            let distance = Float(index) - center
            velocities[index] -= strength * exp(-(distance * distance) / (width * 0.6))
        }
    }

    // MARK: Simulation

    /// Advances the simulation.
    /// - Parameters:
    ///   - accel: window acceleration in pt/s², y-down.
    ///   - gain: physics intensity (0 = still).
    ///   - turbulence: 0...1 agitation from streaming tokens.
    ///   - bubbleRate: bubbles per second (subagents at work).
    func step(dt: Float, accel: SIMD2<Float>, gain: Float, turbulence: Float, bubbleRate: Float) {
        wallImpact = 0
        biggestSplash = 0

        let stiffness: Float = 26
        levelVelocity += (stiffness * (targetLevel - level) - 2 * stiffness.squareRoot() * levelVelocity) * dt
        level += levelVelocity * dt

        stepColumns(dt: dt, accel: accel * gain)
        roughen(turbulence: turbulence, verticalAccel: accel.y * gain)
        conserveVolume()

        wallImpact = max(abs(velocities[0]), abs(velocities[columns - 1]))
        extraDamping = max(0, extraDamping - dt * 3)

        if gain > 0 {
            throwSpray(gain: gain)
        }
        if bubbleRate > 0, Float.random(in: 0 ... 1) < bubbleRate * dt {
            spawnBubble()
        }

        stepParticles(dt: dt)
        stepHang(dt: dt, accel: accel * gain)
    }

    private func stepColumns(dt: Float, accel: SIMD2<Float>) {
        let spacing = size.x / Float(columns - 1)
        let substeps = 3
        let h = dt / Float(substeps)
        let speed = min(tuning.waveSpeed, 0.85 * spacing / h) // CFL-stable for tiny vessels
        let c2 = speed * speed / (spacing * spacing)
        // Near-rest viscosity lets invisible ripples die quickly so the engine can sleep.
        let currentEnergy = energy
        let restDamping: Float = currentEnergy < 3 ? 2.8 * (1 - currentEnergy / 3) : 0
        let damping = tuning.damping + extraDamping + restDamping
        let limit = size.y * 0.42
        let ax = max(-24000, min(24000, accel.x))

        for _ in 0 ..< substeps {
            for index in 0 ..< columns {
                let left = heights[max(index - 1, 0)]
                let right = heights[min(index + 1, columns - 1)]
                let offset = Float(index) / Float(columns - 1) - 0.5
                var acceleration = (left + right - 2 * heights[index]) * c2
                acceleration -= tuning.restoring * heights[index] + damping * velocities[index]
                acceleration -= ax * offset * tuning.tiltGain // slosh away from the acceleration
                velocities[index] += acceleration * h
            }
            for index in 0 ..< columns {
                heights[index] = max(-limit, min(limit, heights[index] + velocities[index] * h))
            }
        }
    }

    private func roughen(turbulence: Float, verticalAccel: Float) {
        let roughness = abs(max(-24000, min(24000, verticalAccel))) * 0.0009 + turbulence * 0.9
        guard roughness > 0.001 else { return }
        for _ in 0 ..< max(1, columns / 24) {
            velocities[Int.random(in: 0 ..< columns)] += Float.random(in: -1 ... 1) * roughness * 60
        }
    }

    private func conserveVolume() {
        let mean = heights.reduce(0, +) / Float(columns)
        for index in 0 ..< columns {
            heights[index] -= mean
        }
    }

    private func throwSpray(gain: Float) {
        let threshold = tuning.sprayThreshold / max(gain, 0.3)
        for index in stride(from: 0, to: columns, by: 2) where velocities[index] > threshold {
            guard particles.count < tuning.particleCap, Float.random(in: 0 ... 1) < 0.3 else { continue }
            let x = Float(index) / Float(columns - 1) * size.x
            particles.append(WaterParticle(
                position: [x, size.y * (1 - level) - heights[index] - 2],
                velocity: [.random(in: -70 ... 70), -velocities[index] * 0.75],
                radius: .random(in: 1.4 ... 3.2) * min(1, size.x / 300 + 0.3),
                kind: .drop
            ))
        }
    }

    private func stepParticles(dt: Float) {
        var index = 0
        while index < particles.count {
            var particle = particles[index]
            particle.age += dt
            let keep = switch particle.kind {
            case .drop: stepDrop(&particle, dt: dt)
            case .bubble: stepBubble(&particle, dt: dt)
            }
            if keep {
                particles[index] = particle
                index += 1
            } else {
                particles.remove(at: index)
            }
        }
    }

    /// Returns `false` once the drop has hit the surface or left the vessel.
    private func stepDrop(_ drop: inout WaterParticle, dt: Float) -> Bool {
        drop.velocity.y += tuning.gravity * dt
        drop.position += drop.velocity * dt
        if drop.position.x < drop.radius {
            drop.position.x = drop.radius
            drop.velocity.x = abs(drop.velocity.x) * 0.5
        }
        if drop.position.x > size.x - drop.radius {
            drop.position.x = size.x - drop.radius
            drop.velocity.x = -abs(drop.velocity.x) * 0.5
        }
        let surface = surfaceY(atX: drop.position.x)
        if drop.velocity.y > 0, drop.position.y + drop.radius * 0.4 >= surface {
            let strength = drop.radius * drop.velocity.y * 0.016
            let width = max(2.5, drop.radius * 1.4 * Float(columns) / max(size.x, 1))
            impulse(atX: drop.position.x, strength: strength, width: width)
            biggestSplash = max(biggestSplash, strength)
            if drop.radius > 4.5 {
                splashBack(at: [drop.position.x, surface])
            }
            return false
        }
        return drop.position.y <= size.y + 20
    }

    private func splashBack(at point: SIMD2<Float>) {
        for _ in 0 ..< 3 where particles.count < tuning.particleCap {
            particles.append(WaterParticle(
                position: [point.x, point.y - 2],
                velocity: [.random(in: -110 ... 110), -.random(in: 160 ... 300)],
                radius: .random(in: 1.3 ... 2.4),
                kind: .drop
            ))
        }
    }

    private func stepBubble(_ bubble: inout WaterParticle, dt: Float) -> Bool {
        bubble.velocity.y += (-70 - bubble.velocity.y) * 2.5 * dt
        bubble.position.x += sin(bubble.age * 7 + bubble.seed) * 18 * dt
        bubble.position.y += bubble.velocity.y * dt
        if bubble.position.y - bubble.radius <= surfaceY(atX: bubble.position.x) {
            impulse(atX: bubble.position.x, strength: -14, width: 2) // a tiny upward pop
            return false
        }
        return true
    }

    private func stepHang(dt: Float, accel: SIMD2<Float>) {
        switch hangState {
        case .none:
            hangRadius = 0
        case let .hanging(since):
            // Older requests look heavier: 7 pt growing to 14 pt over 20 seconds.
            let pending = Float(Date.now.timeIntervalSince(since))
            let target = (7 + min(pending, 20) / 20 * 7) * scale
            hangRadius += (target - hangRadius) * min(1, dt * 4)
            let stiffness: Float = 140
            let damping: Float = 5
            hangOffsetVelocity += (-stiffness * hangOffset - damping * hangOffsetVelocity - accel * 0.006) * dt
            hangOffset += hangOffsetVelocity * dt
            hangOffset = simd_clamp(hangOffset, SIMD2(-hangRadius, -2), SIMD2(hangRadius, hangRadius * 0.6))
        case .evaporating:
            hangRadius -= dt * 22
            if hangRadius <= 0 {
                hangRadius = 0
                hangState = .none
            }
        }
    }

    // MARK: Rest & still mode

    var energy: Float {
        var total: Float = 0
        for index in 0 ..< columns {
            total += heights[index] * heights[index] + velocities[index] * velocities[index] * 0.01
        }
        return total / Float(columns)
    }

    /// True when nothing visible would change next frame. A hanging droplet's slow growth
    /// doesn't count, so the engine can sleep; the droplet catches up on the next wake.
    var isSettled: Bool {
        if case .evaporating = hangState {
            return false
        }
        return particles.isEmpty
            && abs(levelVelocity) < 0.0004
            && abs(targetLevel - level) < 0.0004
            && simd_length(hangOffsetVelocity) < 0.05
            && energy < 0.01
    }

    /// Snaps to an exact rest state so a sleeping frame is stable.
    func snapToRest() {
        for index in 0 ..< columns {
            heights[index] = 0
            velocities[index] = 0
        }
        level = targetLevel
        levelVelocity = 0
        hangOffset = .zero
        hangOffsetVelocity = .zero
    }

    /// Reduce Motion / Still: no waves or particles; the level eases without sloshing.
    func stepStill(dt: Float) {
        for index in 0 ..< columns {
            heights[index] = 0
            velocities[index] = 0
        }
        particles.removeAll()
        level += (targetLevel - level) * min(1, dt * 6)
        if abs(targetLevel - level) < 0.0004 {
            level = targetLevel
        }
        levelVelocity = 0
        switch hangState {
        case .hanging: hangRadius = 10 * scale
        case .evaporating, .none:
            hangRadius = 0
            hangState = .none
        }
        hangOffset = .zero
    }

    // MARK: Render packing

    /// Particles packed as `[x, y, radius, kind]` for the shader. Never empty.
    func packedParticles() -> [Float] {
        guard !particles.isEmpty else { return [0, 0, 0, -1] }
        var packed: [Float] = []
        packed.reserveCapacity(particles.count * 4)
        for particle in particles {
            packed += [particle.position.x, particle.position.y, particle.radius, particle.kind.rawValue]
        }
        return packed
    }

    /// `[x, y, radius, alpha]`, or zero when no droplet is shown.
    func packedHang() -> SIMD4<Float> {
        guard hangRadius > 0.5 else { return .zero }
        let center = hangCenter
        let alpha: Float = if case .evaporating = hangState {
            0.5
        } else {
            1
        }
        return SIMD4(center.x, center.y, hangRadius, alpha)
    }
}
