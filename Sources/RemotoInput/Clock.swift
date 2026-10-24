import Foundation

/// Time source of the engine, in seconds on a monotonic timeline. The engine
/// blocks its own thread for the short holds of SPEC §10.6 (2, 8 and 12 ms), so
/// sleeping is part of the clock: a manual clock in tests just moves forward.
protocol EngineClock {
    func now() -> Double
    func sleep(_ seconds: Double)
}

/// The real clock: `CLOCK_UPTIME_RAW`, the same timeline as `DispatchTime`.
struct MonotonicClock: EngineClock, Sendable {
    func now() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
    }

    func sleep(_ seconds: Double) {
        guard seconds > 0 else { return }
        Thread.sleep(forTimeInterval: seconds)
    }
}

/// A clock that only moves when told to (or when the engine sleeps).
/// Single-threaded: it belongs to whoever drives an `EngineCore` by hand.
final class ManualClock: EngineClock {
    private(set) var current: Double

    init(_ start: Double = 1000) {
        current = start
    }

    func now() -> Double { current }

    func sleep(_ seconds: Double) {
        if seconds > 0 { current += seconds }
    }

    func set(_ time: Double) {
        if time > current { current = time }
    }
}
