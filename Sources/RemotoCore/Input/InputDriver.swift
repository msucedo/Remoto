import Foundation

/// The core's view of the input engine. Production uses `InputEngine`; tests
/// use a fake that records what it was asked to do.
protocol InputDriver: Sendable {
    func send(_ input: Input, session: UInt64)
    func alive(session: UInt64)
    func forget(session: UInt64)
    func setPaused(_ paused: Bool)
    func setTiming(_ timing: InputTiming)
    func setLayout(_ layout: KeyboardLayout?)
    /// Returns once earlier commands were posted (at most ~1 s).
    func flush() async
    func shutdown()
    /// Accessibility permission (`features.permission`).
    var isTrusted: Bool { get }
}

typealias InputNoticeHandler = @Sendable (_ session: UInt64, _ notice: InputNotice) -> Void

/// Which input backend the host uses.
public enum InputBackend: Sendable {
    /// The real engine with the given sink (`.system` posts events, `.log` records them).
    case engine(InputSinkKind)
    /// Accepts and drops everything. For development when the engine isn't available.
    case discard
}

/// Lets the engine call back into the host once the host exists.
final class NoticeRelay: Sendable {
    private let target = Locked<InputNoticeHandler?>(nil)
    func set(_ handler: @escaping InputNoticeHandler) { target.set(handler) }
    func fire(_ session: UInt64, _ notice: InputNotice) { target.value?(session, notice) }
}

struct EngineDriver: InputDriver {
    let engine: InputEngine

    init(sink: InputSinkKind, relay: NoticeRelay) {
        engine = InputEngine(sink: sink, onNotice: { relay.fire($0, $1) })
    }

    func send(_ input: Input, session: UInt64) { engine.send(input, session: session) }
    func alive(session: UInt64) { engine.alive(session: session) }
    func forget(session: UInt64) { engine.forget(session: session) }
    func setPaused(_ paused: Bool) { engine.setPaused(paused) }
    func setTiming(_ timing: InputTiming) { engine.setTiming(timing) }
    func setLayout(_ layout: KeyboardLayout?) { engine.setLayout(layout) }
    func flush() async { await engine.flush() }
    func shutdown() { engine.shutdown() }
    var isTrusted: Bool { InputEngine.isTrusted }
}

struct DiscardDriver: InputDriver {
    func send(_ input: Input, session: UInt64) {}
    func alive(session: UInt64) {}
    func forget(session: UInt64) {}
    func setPaused(_ paused: Bool) {}
    func setTiming(_ timing: InputTiming) {}
    func setLayout(_ layout: KeyboardLayout?) {}
    func flush() async {}
    func shutdown() {}
    var isTrusted: Bool { true }
}
