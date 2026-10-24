import Dispatch
import os

/// Runs host delegate calls (which may block) on GCD threads instead of the
/// Swift concurrency pool.
enum Blocking {
    private static let queue = DispatchQueue(
        label: "remoto-blocking", qos: .userInitiated, attributes: .concurrent)

    static func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }
}

/// A small mutable box guarded by an unfair lock.
final class Locked<Value: Sendable>: Sendable {
    private let lock: OSAllocatedUnfairLock<Value>

    init(_ value: Value) { lock = OSAllocatedUnfairLock(initialState: value) }

    var value: Value { lock.withLock { $0 } }

    @discardableResult
    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        try lock.withLockUnchecked { try body(&$0) }
    }

    func set(_ value: Value) { lock.withLock { $0 = value } }
}
