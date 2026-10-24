import Foundation

// Pure motion logic of SPEC §10.3 and §10.4: pacer, fling, scroll accumulators.
// No clocks of their own; every call gets `now` in seconds.

enum MotionConstants {
    static let pacerPeriod = 0.004167
    static let flingPeriod = 0.008333
    static let flingMinDt = 0.0041665
    static let scrollAutoEnd = 0.300
    static let deltaLimit = 4000.0
    static let flingMinSpeed = 80.0
    static let flingMaxSpeed = 12000.0
    static let flingStopSpeed = 12.0
    static let flingMaxDuration = 4.0
    static let flingFriction = 2.6
    static let flingMaxDt = 0.024999
    static let subpixel = 1.5
}

/// Clamps to ±4000 (SPEC §10.3, §10.4).
func clampDelta(_ v: Double) -> Double {
    min(max(v, -MotionConstants.deltaLimit), MotionConstants.deltaLimit)
}

struct Vector2: Equatable {
    var x: Double
    var y: Double
    static let zero = Vector2(x: 0, y: 0)
    var isZero: Bool { x == 0 && y == 0 }
}

/// Spreads pointer motion over the expected gap until the next packet, so a
/// 60 Hz phone stream comes out at the 240 Hz tick without stutter (SPEC §10.3).
struct Pacer {
    private(set) var pending = Vector2.zero
    private(set) var lastPush: Double?
    private(set) var avg = 0.016
    private(set) var jit = 0.002
    private(set) var start = 0.0
    private(set) var deadline = 0.0

    var hasPending: Bool { !pending.isZero }

    mutating func push(dx: Double, dy: Double, now: Double) {
        if let lastPush {
            let dt = now - lastPush
            if dt < 0.1 {
                let sample = min(abs(dt - avg), 0.034)
                avg = min(max(0.2 * dt + 0.8 * avg, 0.004), 0.034)
                jit = 0.85 * jit + 0.15 * sample
            }
        }
        lastPush = now
        pending.x += dx
        pending.y += dy
        start = now
        deadline = now + min(avg + min(max(2 * jit, 0.002), 0.010), 0.034)
    }

    /// What should be posted now, if anything.
    mutating func deliver(now: Double) -> Vector2? {
        guard hasPending, now > start else { return nil }
        let emit: Vector2
        if now >= deadline {
            emit = pending
            pending = .zero
        } else {
            let f = (now - start) / (deadline - start)
            emit = Vector2(x: pending.x * f, y: pending.y * f)
            pending.x -= emit.x
            pending.y -= emit.y
        }
        start = now
        return emit
    }

    /// Everything pending, at once (before a click or a key, SPEC §10.2).
    mutating func takeAll() -> Vector2? {
        guard hasPending else { return nil }
        defer { pending = .zero }
        return pending
    }

    /// Drops pending motion (pause, forget).
    mutating func clear() {
        pending = .zero
    }
}

/// Momentum scrolling after a fling (SPEC §10.4).
struct Fling {
    enum Step: Equatable {
        /// Too soon after the previous tick; try again later.
        case wait
        /// Post a momentum scroll with this delta.
        case scroll(dx: Double, dy: Double, momentum: UInt8)
        /// Over; post `momentum 3` if `started`.
        case end(started: Bool)
    }

    private(set) var vx: Double
    private(set) var vy: Double
    let start: Double
    private(set) var last: Double
    private(set) var started = false

    /// Nil if the velocity is not finite or under the threshold.
    init?(vx: Double, vy: Double, now: Double) {
        guard vx.isFinite, vy.isFinite else { return nil }
        let speed = hypot(vx, vy)
        guard speed >= MotionConstants.flingMinSpeed else { return nil }
        let scale = speed > MotionConstants.flingMaxSpeed ? MotionConstants.flingMaxSpeed / speed : 1
        self.vx = vx * scale
        self.vy = vy * scale
        start = now
        last = now
    }

    var speed: Double { hypot(vx, vy) }
    var nextTick: Double { last + MotionConstants.flingPeriod }

    mutating func tick(now: Double) -> Step {
        let dt = now - last
        if dt < MotionConstants.flingMinDt { return .wait }
        last = now
        let decay = exp(-max(MotionConstants.flingFriction, 0.1) * dt)
        vx *= decay
        vy *= decay
        if speed >= MotionConstants.flingStopSpeed, now - start <= MotionConstants.flingMaxDuration {
            let step = min(dt, MotionConstants.flingMaxDt)
            let momentum: UInt8 = started ? 2 : 1
            started = true
            return .scroll(dx: vx * step, dy: vy * step, momentum: momentum)
        }
        return .end(started: started)
    }
}

/// Integer wheel deltas with the fraction carried per axis (SPEC §10.4).
struct ScrollAccumulator {
    private(set) var accX = 0.0
    private(set) var accY = 0.0

    /// Returns (wheel1 = vertical, wheel2 = horizontal).
    mutating func wheels(phase: UInt8, momentum: UInt8, dx: Double, dy: Double) -> (Int32, Int32) {
        if (phase != 0 && phase != 2) || momentum == 3 {
            // Began, ended, cancelled and the momentum end start from zero and carry nothing.
            accX = 0
            accY = 0
            return (Int32(dy.rounded(.towardZero)), Int32(dx.rounded(.towardZero)))
        }
        let y = (dy + accY).rounded(.towardZero)
        let x = (dx + accX).rounded(.towardZero)
        accY = dy + accY - y
        accX = dx + accX - x
        return (Int32(y), Int32(x))
    }
}

/// Integer part of the posted motion with the fraction carried (SPEC §10.3).
struct FractionAccumulator {
    private(set) var acc = 0.0

    mutating func take(_ v: Double) -> Int64 {
        acc += v
        let whole = acc.rounded(.towardZero)
        acc -= whole
        return Int64(whole)
    }
}

/// Counts consecutive clicks (SPEC §10.5).
struct ClickTracker {
    struct Last {
        var button: MouseButton
        var time: Double
        var x: Double
        var y: Double
        var count: Int
    }

    private(set) var last: Last?
    static let maxDistance = 5.0

    /// The click count for a new press of `button`.
    func nextCount(button: MouseButton, now: Double, x: Double, y: Double, window: Double) -> Int {
        guard let last, last.button == button, now - last.time <= window,
            hypot(x - last.x, y - last.y) <= Self.maxDistance
        else { return 1 }
        return last.count + 1
    }

    mutating func record(button: MouseButton, now: Double, x: Double, y: Double, count: Int) {
        last = Last(button: button, time: now, x: x, y: y, count: count)
    }

    /// `clickState` of the release of `button`.
    func releaseCount(button: MouseButton) -> Int {
        guard let last, last.button == button else { return 1 }
        return max(last.count, 1)
    }
}
