import Darwin
import Foundation

/// Monotonic seconds (includes time asleep), used for every timeout and window.
enum Mono {
    static func now() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }
}

/// UNIX seconds, used only for values that get stored or shown.
enum Unix {
    static func now() -> Int64 { Int64(Date().timeIntervalSince1970) }
}

extension Duration {
    static func secondsDouble(_ value: Double) -> Duration { .nanoseconds(Int64(value * 1_000_000_000)) }
}
