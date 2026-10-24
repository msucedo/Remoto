import ApplicationServices
import Foundation
import os

// CONTRACT for the core. The public signatures in this file are fixed; the
// implementation (and everything internal to RemotoInput) is free.

/// Where the engine's events end up. `.system` posts real CGEvents; `.log`
/// records them so tests and `remoto-dev` never touch the real pointer.
public enum InputSinkKind: Sendable {
    case system
    case log(EventLog)
}

/// Thread-safe record of what a `.log` sink would have posted, one line per event.
public final class EventLog: Sendable {
    private let storage = OSAllocatedUnfairLock<[String]>(initialState: [])

    public init() {}

    public var lines: [String] { storage.withLock { $0 } }

    public func clear() { storage.withLock { $0.removeAll() } }

    func append(_ line: String) { storage.withLock { $0.append(line) } }
}

/// Single-threaded injection engine (SPEC §10, §11). Owns a dedicated
/// user-interactive thread; every method only enqueues a command and returns.
public final class InputEngine: Sendable {
    private let queue = CommandQueue()
    private let stop = StopSignal()
    private let clock = MonotonicClock()
    /// Signalled once by the engine thread when it exits.
    private let finished = DispatchSemaphore(value: 0)
    private let stopping = OSAllocatedUnfairLock(initialState: false)

    /// `onNotice` runs on the engine thread, at most once per (kind, session) every 4 s.
    public init(sink: InputSinkKind, onNotice: @escaping @Sendable (_ session: UInt64, _ notice: InputNotice) -> Void) {
        let thread = Thread { [queue, stop, finished] in
            let eventSink: any EventSink =
                switch sink {
                case .system: SystemSink()
                case let .log(log): LogSink(log: log)
                }
            let core = EngineCore(sink: eventSink, clock: MonotonicClock(), stop: stop, onNotice: onNotice)
            EngineLoop.run(core, queue: queue)
            finished.signal()
        }
        thread.name = "remoto-input"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    deinit {
        if !isStopping { queue.push(.shutdown) }
    }

    private var isStopping: Bool { stopping.withLock { $0 } }

    private func enqueue(_ command: EngineCommand) {
        guard !isStopping else { return }
        queue.push(command)
    }

    public func send(_ input: Input, session: UInt64) {
        enqueue(.input(session: session, input: input, at: clock.now()))
    }

    /// Any binary frame from the session counts as a sign of life.
    public func alive(session: UInt64) {
        enqueue(.alive(session: session))
    }

    /// The session ended: drop its pending motion and release what it holds.
    public func forget(session: UInt64) {
        // Visible at once, so text already being typed for it stops.
        stop.forget(session)
        enqueue(.forget(session: session))
    }

    public func setPaused(_ paused: Bool) {
        stop.setPaused(paused)
        enqueue(.setPaused(paused))
    }

    public func setTiming(_ timing: InputTiming) {
        enqueue(.setTiming(timing))
    }

    public func setLayout(_ layout: KeyboardLayout?) {
        enqueue(.setLayout(layout))
    }

    /// Returns once everything sent before it was posted, or after 1 s.
    public func flush() async {
        guard !isStopping else { return }
        let waiter = FlushWaiter()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiter.install(continuation)
            queue.push(.flush { waiter.resume() })
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1) { waiter.resume() }
        }
    }

    /// Releases everything and stops the thread; waits for it.
    public func shutdown() {
        let first = stopping.withLock { already in
            defer { already = true }
            return !already
        }
        guard first else { return }
        queue.push(.shutdown)
        if Thread.current.name == "remoto-input" { return }
        finished.wait()
        finished.signal()
    }

    /// Accessibility trust (whether posting events works).
    public static var isTrusted: Bool { AXIsProcessTrusted() }
}

/// The engine thread's loop (SPEC §10.1): wait for a command until the next
/// timer deadline, process it and everything already queued, run due timers.
enum EngineLoop {
    static func run(_ core: EngineCore, queue: CommandQueue) {
        loop: while true {
            let timeout: DispatchTime
            if let deadline = core.nextDeadline() {
                let wait = max(0, deadline - core.clock.now())
                timeout = .now() + .nanoseconds(Int(wait * 1_000_000_000))
            } else {
                timeout = .distantFuture
            }
            if let command = queue.pop(until: timeout) {
                if !core.process(command) { break loop }
                while let next = queue.pop(until: .now()) {
                    if !core.process(next) { break loop }
                }
            }
            core.runTimers()
        }
        // Commands that arrived after shutdown: answer pending flushes.
        while let late = queue.pop(until: .now()) {
            if case let .flush(ack) = late { ack() }
        }
    }
}

/// FIFO of engine commands. One semaphore count per queued command; the
/// array itself is behind an unfair lock, so the type is plainly `Sendable`.
final class CommandQueue: Sendable {
    private struct Storage: Sendable {
        var items: [EngineCommand] = []
        var head = 0

        mutating func popFirst() -> EngineCommand? {
            guard head < items.count else { return nil }
            let c = items[head]
            head += 1
            if head > 256, head * 2 > items.count {
                items.removeFirst(head)
                head = 0
            }
            return c
        }
    }

    private let storage = OSAllocatedUnfairLock(initialState: Storage())
    private let available = DispatchSemaphore(value: 0)

    func push(_ command: EngineCommand) {
        storage.withLock { $0.items.append(command) }
        available.signal()
    }

    /// The oldest command, or nil if none arrives before `deadline`.
    func pop(until deadline: DispatchTime) -> EngineCommand? {
        guard available.wait(timeout: deadline) == .success else { return nil }
        return storage.withLock { $0.popFirst() }
    }
}

/// Resumes a `flush()` exactly once: on the engine's ack or on the 1 s timeout.
final class FlushWaiter: Sendable {
    private let state = OSAllocatedUnfairLock<(continuation: CheckedContinuation<Void, Never>?, done: Bool)>(
        initialState: (nil, false))

    func install(_ c: CheckedContinuation<Void, Never>) {
        let resumeNow = state.withLock { s -> Bool in
            if s.done { return true }
            s.continuation = c
            return false
        }
        if resumeNow { c.resume() }
    }

    func resume() {
        let c = state.withLock { s -> CheckedContinuation<Void, Never>? in
            s.done = true
            defer { s.continuation = nil }
            return s.continuation
        }
        c?.resume()
    }
}
