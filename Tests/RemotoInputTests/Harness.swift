import CoreGraphics
@testable import RemotoInput

/// Drives an `EngineCore` by hand with a manual clock and a log sink.
/// Nothing here can post a real event.
final class Harness {
    final class Notices {
        var items: [(session: UInt64, notice: InputNotice)] = []
    }

    let clock = ManualClock()
    let log = EventLog()
    let sink: LogSink
    let notices = Notices()
    let core: EngineCore

    init() {
        sink = LogSink(log: log)
        let box = notices
        core = EngineCore(sink: sink, clock: clock) { session, notice in
            box.items.append((session, notice))
        }
    }

    var now: Double { clock.now() }

    func send(_ input: Input, session: UInt64 = 1) {
        core.process(.input(session: session, input: input, at: clock.now()))
    }

    func process(_ command: EngineCommand) {
        core.process(command)
    }

    /// Moves time forward, firing timers at their deadlines like the real loop.
    func advance(_ dt: Double) {
        let target = clock.now() + dt
        var guardCount = 0
        while let d = core.nextDeadline(), d <= target {
            clock.set(d)
            core.runTimers()
            guardCount += 1
            precondition(guardCount < 1_000_000, "timer loop does not advance")
        }
        clock.set(target)
    }

    var events: [SinkEvent] { sink.events }

    func clear() { sink.clear() }

    /// Keyboard events only, as (code, down, flags) with flagsChanged reported as down=nil.
    var keys: [KeyRecord] {
        events.compactMap {
            switch $0 {
            case let .key(code, down, flags, autorepeat, text):
                KeyRecord(code: code, kind: down ? .down : .up, flags: flags, autorepeat: autorepeat, text: text)
            case let .flagsChanged(code, flags):
                KeyRecord(code: code, kind: .flags, flags: flags, autorepeat: false, text: nil)
            default:
                nil
            }
        }
    }

    var scrolls: [ScrollEvent] {
        events.compactMap { if case let .scroll(e) = $0 { e } else { nil } }
    }

    var buttons: [ButtonRecord] {
        events.compactMap {
            if case let .mouse(kind, button, _, _, _, _, clickState, _) = $0, kind == .down || kind == .up {
                ButtonRecord(kind: kind, button: button, clickState: clickState)
            } else {
                nil
            }
        }
    }

    var moves: [MoveRecord] {
        events.compactMap {
            if case let .mouse(kind, button, x, y, dx, dy, _, _) = $0, kind == .moved || kind == .dragged {
                MoveRecord(kind: kind, button: button, x: x, y: y, dx: dx, dy: dy)
            } else {
                nil
            }
        }
    }
}

struct KeyRecord: Equatable {
    enum Kind { case down, up, flags }
    var code: UInt16
    var kind: Kind
    var flags: UInt64
    var autorepeat: Bool
    var text: String? = nil
}

struct ButtonRecord: Equatable {
    var kind: MouseEventKind
    var button: MouseButton
    var clickState: Int64
}

struct MoveRecord: Equatable {
    var kind: MouseEventKind
    var button: MouseButton
    var x: Double
    var y: Double
    var dx: Int64
    var dy: Int64
}

func approx(_ a: Double, _ b: Double, _ eps: Double = 1e-9) -> Bool { abs(a - b) <= eps }
