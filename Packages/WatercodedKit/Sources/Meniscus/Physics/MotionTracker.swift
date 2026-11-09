import Foundation
import simd

/// How hard the window is being shaken.
public enum ShakeLevel: Int, Comparable, Sendable, CustomStringConvertible {
    case none
    case gentle
    case vigorous
    case violent

    public static func < (lhs: ShakeLevel, rhs: ShakeLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var description: String {
        switch self {
        case .none: "none"
        case .gentle: "gentle"
        case .vigorous: "vigorous"
        case .violent: "violent"
        }
    }
}

/// Turns a stream of window origins into velocity, acceleration and a ``ShakeLevel``.
///
/// A shake is direction reversals of fast motion inside a sliding window:
/// at least 3 reversals within 600 ms is vigorous; vigorous sustained for 2 s is violent.
struct MotionTracker {
    struct Reading {
        var velocity: SIMD2<Double>
        var acceleration: SIMD2<Double>
        var level: ShakeLevel

        static let still = Reading(velocity: .zero, acceleration: .zero, level: .none)
    }

    var reversalWindow = 0.6
    var reversalSpeed: Double = 260
    var reversalsForVigorous = 3
    var violentAfter = 2.0

    private var lastPosition: SIMD2<Double>?
    private(set) var velocity: SIMD2<Double> = .zero
    private(set) var acceleration: SIMD2<Double> = .zero
    private var lastSign: SIMD2<Int> = .zero
    private var reversals: [Double] = []
    private var vigorousSince: Double?
    private var lastMoveTime: Double = -.infinity
    private(set) var level: ShakeLevel = .none

    var reversalCount: Int {
        reversals.count
    }

    mutating func reset() {
        self = MotionTracker(
            reversalWindow: reversalWindow,
            reversalSpeed: reversalSpeed,
            reversalsForVigorous: reversalsForVigorous,
            violentAfter: violentAfter
        )
    }

    /// - Parameter position: window origin in screen points (AppKit, y-up).
    mutating func update(position: SIMD2<Double>, dt: Double, now: Double) -> Reading {
        defer { lastPosition = position }
        guard let lastPosition, dt > 0 else { return Reading(velocity: .zero, acceleration: .zero, level: level) }

        let delta = position - lastPosition
        if simd_length(delta) > 0.01 {
            lastMoveTime = now
        }

        // Window frames can arrive slower than the display refreshes; smoothing keeps a missed
        // frame from reading as a huge deceleration spike.
        let smoothedVelocity = velocity + (delta / dt - velocity) * 0.5
        acceleration += ((smoothedVelocity - velocity) / dt - acceleration) * 0.45
        velocity = smoothedVelocity

        for axis in 0 ..< 2 where abs(velocity[axis]) > reversalSpeed {
            let sign = velocity[axis] > 0 ? 1 : -1
            if lastSign[axis] != 0, sign != lastSign[axis] {
                reversals.append(now)
            }
            lastSign[axis] = sign
        }
        reversals.removeAll { now - $0 > reversalWindow }

        var newLevel: ShakeLevel = simd_length(velocity) > 40 ? .gentle : .none
        if reversals.count >= reversalsForVigorous {
            newLevel = .vigorous
            if vigorousSince == nil {
                vigorousSince = now
            }
            if let vigorousSince, now - vigorousSince >= violentAfter {
                newLevel = .violent
            }
        } else if now - lastMoveTime > 0.35 {
            vigorousSince = nil
        } else if vigorousSince != nil, level >= .vigorous {
            newLevel = level // a brief lull inside a long shake keeps the streak alive
        }
        level = newLevel
        return Reading(velocity: velocity, acceleration: acceleration, level: level)
    }

    func isStill(now: Double) -> Bool {
        now - lastMoveTime > 0.25 && simd_length(velocity) < 5
    }
}
