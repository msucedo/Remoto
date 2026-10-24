import CoreGraphics
import Foundation
import os

/// A command for the engine thread (SPEC §10.1).
enum EngineCommand: Sendable {
    case input(session: UInt64, input: Input, at: Double)
    case alive(session: UInt64)
    case forget(session: UInt64)
    case setPaused(Bool)
    case setTiming(InputTiming)
    case setLayout(KeyboardLayout?)
    case flush(@Sendable () -> Void)
    case shutdown
}

/// Clamped `InputTiming` in seconds (SPEC §10.8).
struct EngineTiming: Equatable {
    var repeatDelay = 0.5
    var repeatInterval = 0.083
    var doubleClick = 0.5

    init() {}

    init(_ t: InputTiming) {
        repeatDelay = Double(min(max(t.repeatDelayMs, 100), 3000)) / 1000
        repeatInterval = Double(min(max(t.repeatIntervalMs, 15), 2000)) / 1000
        doubleClick = Double(min(max(t.doubleClickMs, 150), 5000)) / 1000
    }
}

enum EngineConstants {
    static let tapHold = 0.012
    static let typeHold = 0.002
    static let modifierPause = 0.008
    static let segmentPause = 0.002
    static let repeatLimit = 60.0
    static let repeatSilence = 3.0
    static let watchdogPeriod = 0.25
    static let watchdogSilence = 5
    static let statusCache = 0.75
    static let displayCache = 1.0
    static let noticeInterval = 4.0
    static let forgottenLimit = 256
}

/// Session ids that ended, the most recent 256 (SPEC §10.1).
struct ForgottenSessions: Sendable {
    private var order: [UInt64] = []
    private var set: Set<UInt64> = []

    func contains(_ s: UInt64) -> Bool { set.contains(s) }

    mutating func insert(_ s: UInt64) {
        guard set.insert(s).inserted else { return }
        order.append(s)
        if order.count > EngineConstants.forgottenLimit {
            set.remove(order.removeFirst())
        }
    }
}

/// Pause and forgotten sessions as seen from outside the engine thread, so a
/// long text or a run of backspaces stops as soon as the host asks (SPEC §8.7).
final class StopSignal: Sendable {
    private struct State: Sendable {
        var paused = false
        var forgotten = ForgottenSessions()
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func setPaused(_ p: Bool) { state.withLock { $0.paused = p } }
    func forget(_ s: UInt64) { state.withLock { $0.forgotten.insert(s) } }

    func shouldStop(_ s: UInt64) -> Bool {
        state.withLock { $0.paused || $0.forgotten.contains(s) }
    }
}

/// One rate-limit slot per (kind, session) (SPEC §10.2).
struct NoticeLimiter {
    private struct Key: Hashable {
        var notice: InputNotice
        var session: UInt64
    }

    private var last: [Key: Double] = [:]

    mutating func allow(_ notice: InputNotice, session: UInt64, now: Double) -> Bool {
        let key = Key(notice: notice, session: session)
        if let t = last[key], now - t < EngineConstants.noticeInterval { return false }
        last[key] = now
        return true
    }

    mutating func forget(session: UInt64) {
        last = last.filter { $0.key.session != session }
    }
}

/// A value read from the system, kept for a while.
struct Cached<Value> {
    private var value: Value?
    private var at = 0.0
    let lifetime: Double

    init(lifetime: Double) { self.lifetime = lifetime }

    mutating func get(now: Double, _ read: () -> Value) -> Value {
        if let value, now - at < lifetime { return value }
        let v = read()
        value = v
        at = now
        return v
    }

    mutating func invalidate() { value = nil }
}

/// All engine state. Single-threaded: it lives on the engine thread (or in a
/// test that drives it with a manual clock). Implements SPEC §10 and §11.
final class EngineCore {
    struct Session {
        var lastSignal: Double
        /// Held keys in press order, each with the temporary modifiers it pressed.
        var keys: [(code: UInt16, temps: [UInt16])] = []
        var buttons: [MouseButton] = []
        var media: [MediaKey] = []

        var holdsSomething: Bool { !keys.isEmpty || !buttons.isEmpty || !media.isEmpty }
        func holds(_ code: UInt16) -> Bool { keys.contains { $0.code == code } }
    }

    struct Repeat {
        var code: UInt16
        var session: UInt64
        var next: Double
        var end: Double
    }

    let sink: any EventSink
    let clock: any EngineClock
    let stop: StopSignal
    let onNotice: (UInt64, InputNotice) -> Void

    private(set) var paused = false
    private var forgotten = ForgottenSessions()
    private(set) var timing = EngineTiming()
    private(set) var charMap = CharacterMap()
    private(set) var sessions: [UInt64: Session] = [:]

    private(set) var pacer = Pacer()
    private var pacerNext: Double?
    private var lastPosted: CGPoint?
    private var fracX = FractionAccumulator()
    private var fracY = FractionAccumulator()

    private(set) var scrollActive = false
    private var scrollLast = 0.0
    private var scrollAcc = ScrollAccumulator()
    private(set) var fling: Fling?
    private var flingNext: Double?

    private(set) var keys = KeyRefcount()
    private(set) var buttons = ButtonRefcount()
    private var clicks = ClickTracker()
    private(set) var autorepeat: Repeat?
    private var watchdogNext: Double?

    private var notices = NoticeLimiter()
    private var trustedCache = Cached<Bool>(lifetime: EngineConstants.statusCache)
    private var secureCache = Cached<Bool>(lifetime: EngineConstants.statusCache)
    private var capsCache = Cached<Bool>(lifetime: EngineConstants.statusCache)
    private var displayCache = Cached<[CGRect]>(lifetime: EngineConstants.displayCache)

    init(sink: any EventSink, clock: any EngineClock, stop: StopSignal = StopSignal(), onNotice: @escaping (UInt64, InputNotice) -> Void) {
        self.sink = sink
        self.clock = clock
        self.stop = stop
        self.onNotice = onNotice
    }

    // MARK: Loop interface

    /// Handles one command; false means shut down.
    @discardableResult
    func process(_ command: EngineCommand) -> Bool {
        switch command {
        case let .input(session, input, at):
            handle(input, session: session, at: at)
        case let .alive(session):
            if !shouldStop(session) { signal(session) }
        case let .forget(session):
            forget(session)
        case let .setPaused(p):
            setPaused(p)
        case let .setTiming(t):
            timing = EngineTiming(t)
        case let .setLayout(layout):
            charMap = CharacterMap(layout)
        case let .flush(ack):
            flushPacer()
            ack()
        case .shutdown:
            shutdown()
            return false
        }
        return true
    }

    /// The earliest timer deadline, if any timer is armed.
    func nextDeadline() -> Double? {
        var d: Double?
        func consider(_ t: Double?) {
            guard let t else { return }
            d = min(d ?? t, t)
        }
        consider(pacerNext)
        consider(flingNext)
        if scrollActive { consider(scrollLast + MotionConstants.scrollAutoEnd) }
        consider(autorepeat?.next)
        consider(watchdogNext)
        return d
    }

    /// Runs every timer that is due.
    func runTimers() {
        let now = clock.now()
        if let t = pacerNext, now >= t { pacerTick(now) }
        if let t = flingNext, now >= t { flingTick(now) }
        if scrollActive, now >= scrollLast + MotionConstants.scrollAutoEnd {
            postScroll(phase: 4, momentum: 0, dx: 0, dy: 0)
            scrollActive = false
        }
        if let r = autorepeat, now >= r.next { repeatTick(now) }
        if let t = watchdogNext, now >= t { watchdogTick(now) }
    }

    /// Releases everything (end of the engine).
    func shutdown() {
        pacer.clear()
        pacerNext = nil
        cancelFling()
        endScrollGesture()
        releaseAll()
    }

    // MARK: Sessions

    func shouldStop(_ session: UInt64) -> Bool {
        paused || forgotten.contains(session) || stop.shouldStop(session)
    }

    private func signal(_ session: UInt64) {
        let now = clock.now()
        if sessions[session] == nil {
            sessions[session] = Session(lastSignal: now)
        } else {
            sessions[session]?.lastSignal = now
        }
    }

    private func forget(_ session: UInt64) {
        forgotten.insert(session)
        stop.forget(session)
        pacer.clear()
        pacerNext = nil
        releaseSession(session)
        sessions[session] = nil
        notices.forget(session: session)
    }

    private func setPaused(_ p: Bool) {
        paused = p
        stop.setPaused(p)
        guard p else { return }
        pacer.clear()
        pacerNext = nil
        cancelFling()
        endScrollGesture()
        releaseAll()
    }

    private func notify(_ notice: InputNotice, session: UInt64) {
        if notices.allow(notice, session: session, now: clock.now()) {
            onNotice(session, notice)
        }
    }

    // MARK: Input dispatch (SPEC §10.2)

    private func handle(_ input: Input, session: UInt64, at: Double) {
        if shouldStop(session) { return }
        signal(session)
        if case .move = input {} else { flushPacer() }

        switch input {
        case .touch, .release: break
        default:
            let now = clock.now()
            if !trustedCache.get(now: now, { sink.isTrusted() }) { notify(.accessibility, session: session) }
        }
        if input.isTyping {
            let now = clock.now()
            if secureCache.get(now: now, { sink.secureInputEnabled() }) { notify(.secureInput, session: session) }
        }

        switch input {
        case let .move(dx, dy):
            move(dx: dx, dy: dy, at: at)
        case let .scroll(phase, dx, dy):
            scroll(phase: phase, dx: dx, dy: dy)
        case let .fling(vx, vy):
            startFling(vx: vx, vy: vy)
        case .touch:
            cancelFling()
        case let .key(code, down, mods, repeats):
            if down {
                keyDown(code, mods: mods, repeats: repeats, session: session)
            } else {
                keyUp(code, session: session)
            }
        case let .tap(code, mods):
            tap(code, mods: mods, hold: EngineConstants.tapHold)
        case let .tapChar(code, mods, char):
            tap(resolve(char) ?? code, mods: mods, hold: EngineConstants.tapHold)
        case let .button(button, op):
            switch op {
            case .down: buttonDown(button, session: session)
            case .up: buttonUp(button, session: session)
            case .click: click(button, count: 1)
            }
        case let .click(button, count):
            click(button, count: min(max(count, 1), 3))
        case let .media(key, op):
            media(key, op: op, session: session)
        case let .text(text, keystrokes):
            type(text, keystrokes: keystrokes, session: session)
        case let .edit(delete, insert):
            edit(delete: delete, insert: insert, session: session)
        case .release:
            releaseSession(session)
        }
        armWatchdog()
    }

    /// Keycode of a letter on the active layout's unmodified level (SPEC §13.2).
    private func resolve(_ char: Character) -> UInt16? {
        let lower = String(char).lowercased()
        guard lower.count == 1, let ch = lower.first else { return nil }
        return charMap.baseCode(ch)
    }

    // MARK: Pointer (SPEC §10.3)

    private func move(dx: Double, dy: Double, at: Double) {
        guard dx.isFinite, dy.isFinite, dx != 0 || dy != 0 else { return }
        if let d = pacer.deliver(now: at) { postMove(d) }
        pacer.push(dx: clampDelta(dx), dy: clampDelta(dy), now: at)
        if pacerNext == nil { pacerNext = clock.now() + MotionConstants.pacerPeriod }
    }

    private func pacerTick(_ now: Double) {
        if let d = pacer.deliver(now: now) { postMove(d) }
        pacerNext = pacer.hasPending ? now + MotionConstants.pacerPeriod : nil
    }

    private func flushPacer() {
        if let d = pacer.takeAll() { postMove(d) }
        pacerNext = nil
    }

    private func postMove(_ d: Vector2) {
        let cursor = sink.cursorPosition()
        var base = cursor
        if let last = lastPosted, abs(last.x - cursor.x) < MotionConstants.subpixel, abs(last.y - cursor.y) < MotionConstants.subpixel {
            base = last
        }
        let dest = clampToScreens(CGPoint(x: base.x + d.x, y: base.y + d.y))
        let ix = fracX.take(dest.x - base.x)
        let iy = fracY.take(dest.y - base.y)
        let held = buttons.dragging
        sink.post(
            .mouse(held == nil ? .moved : .dragged, button: held ?? .left, x: dest.x, y: dest.y, dx: ix, dy: iy, clickState: 0, flags: pointerFlags()))
        lastPosted = dest
    }

    private func clampToScreens(_ p: CGPoint) -> CGPoint {
        let screens = displayCache.get(now: clock.now()) { sink.activeDisplays() }.filter { $0.width >= 1 && $0.height >= 1 }
        guard !screens.isEmpty else { return p }
        func clamp(_ r: CGRect) -> CGPoint {
            CGPoint(x: min(max(p.x, r.minX), r.minX + r.width - 1), y: min(max(p.y, r.minY), r.minY + r.height - 1))
        }
        var best = p
        var bestDistance = Double.infinity
        for r in screens {
            let c = clamp(r)
            if c == p { return p }
            let dist = (c.x - p.x) * (c.x - p.x) + (c.y - p.y) * (c.y - p.y)
            if dist < bestDistance {
                bestDistance = dist
                best = c
            }
        }
        return best
    }

    private func capsFlag() -> UInt64 {
        capsCache.get(now: clock.now()) { sink.capsLockIsOn() } ? KeyFlags.capsLock : 0
    }

    private func pointerFlags() -> UInt64 { keys.modifierFlags | capsFlag() }

    // MARK: Scroll and fling (SPEC §10.4)

    private func scroll(phase: UInt8, dx: Double, dy: Double) {
        guard dx.isFinite, dy.isFinite else { return }
        let dx = clampDelta(dx)
        let dy = clampDelta(dy)
        cancelFling()
        switch phase {
        case 0:
            postScroll(phase: 0, momentum: 0, dx: dx, dy: dy)
        case 1:
            if scrollActive { postScroll(phase: 4, momentum: 0, dx: 0, dy: 0) }
            scrollActive = true
            postScroll(phase: 1, momentum: 0, dx: dx, dy: dy)
        case 2:
            if scrollActive {
                postScroll(phase: 2, momentum: 0, dx: dx, dy: dy)
            } else {
                scrollActive = true
                postScroll(phase: 1, momentum: 0, dx: dx, dy: dy)
            }
        case 4, 8:
            if scrollActive {
                postScroll(phase: phase, momentum: 0, dx: 0, dy: 0)
                scrollActive = false
            }
        default:
            return
        }
        if scrollActive { scrollLast = clock.now() }
    }

    private func endScrollGesture() {
        if scrollActive {
            postScroll(phase: 4, momentum: 0, dx: 0, dy: 0)
            scrollActive = false
        }
    }

    private func postScroll(phase: UInt8, momentum: UInt8, dx: Double, dy: Double) {
        let (w1, w2) = scrollAcc.wheels(phase: phase, momentum: momentum, dx: dx, dy: dy)
        let at = sink.cursorPosition()
        sink.post(
            .scroll(
                ScrollEvent(
                    phase: phase, momentum: momentum, wheel1: w1, wheel2: w2, dx: dx, dy: dy, x: at.x, y: at.y,
                    flags: keys.modifierFlags)))
    }

    private func startFling(vx: Double, vy: Double) {
        endScrollGesture()
        guard let f = Fling(vx: vx, vy: vy, now: clock.now()) else { return }
        cancelFling()
        fling = f
        flingNext = f.nextTick
    }

    private func flingTick(_ now: Double) {
        guard var f = fling else {
            flingNext = nil
            return
        }
        switch f.tick(now: now) {
        case .wait:
            flingNext = max(f.nextTick, now + MotionConstants.flingMinDt)
            fling = f
        case let .scroll(dx, dy, momentum):
            postScroll(phase: 0, momentum: momentum, dx: dx, dy: dy)
            fling = f
            flingNext = f.nextTick
        case let .end(started):
            fling = nil
            flingNext = nil
            if started { postScroll(phase: 0, momentum: 3, dx: 0, dy: 0) }
        }
    }

    private func cancelFling() {
        guard let f = fling else { return }
        fling = nil
        flingNext = nil
        if f.started { postScroll(phase: 0, momentum: 3, dx: 0, dy: 0) }
    }

    // MARK: Buttons (SPEC §10.5)

    private func buttonDown(_ b: MouseButton, session: UInt64) {
        guard var st = sessions[session], !st.buttons.contains(b) else { return }
        st.buttons.append(b)
        sessions[session] = st
        guard buttons.press(b) else { return }
        let at = sink.cursorPosition()
        let now = clock.now()
        let count = clicks.nextCount(button: b, now: now, x: at.x, y: at.y, window: timing.doubleClick)
        clicks.record(button: b, now: now, x: at.x, y: at.y, count: count)
        postButton(.down, b, clickState: count, at: at)
    }

    private func buttonUp(_ b: MouseButton, session: UInt64) {
        guard var st = sessions[session], let i = st.buttons.firstIndex(of: b) else { return }
        st.buttons.remove(at: i)
        sessions[session] = st
        releaseButton(b)
    }

    private func releaseButton(_ b: MouseButton) {
        guard buttons.release(b) else { return }
        postButton(.up, b, clickState: clicks.releaseCount(button: b), at: sink.cursorPosition())
    }

    private func click(_ b: MouseButton, count: Int) {
        guard !buttons.isDown(b) else { return }
        let at = sink.cursorPosition()
        let now = clock.now()
        if count == 1 {
            let n = clicks.nextCount(button: b, now: now, x: at.x, y: at.y, window: timing.doubleClick)
            clicks.record(button: b, now: now, x: at.x, y: at.y, count: n)
            postButton(.down, b, clickState: n, at: at)
            postButton(.up, b, clickState: n, at: at)
        } else {
            for n in 1...count {
                postButton(.down, b, clickState: n, at: at)
                postButton(.up, b, clickState: n, at: at)
            }
            clicks.record(button: b, now: now, x: at.x, y: at.y, count: count)
        }
    }

    private func postButton(_ kind: MouseEventKind, _ b: MouseButton, clickState: Int, at: CGPoint) {
        sink.post(.mouse(kind, button: b, x: at.x, y: at.y, dx: 0, dy: 0, clickState: Int64(max(clickState, 1)), flags: pointerFlags()))
    }

    // MARK: Keyboard (SPEC §10.6, §10.7)

    private func keyFlags(_ base: UInt64) -> UInt64 { base | capsFlag() | KeyFlags.nonCoalesced }

    private func toggleCapsLock() {
        sink.toggleCapsLock()
        capsCache.invalidate()
    }

    private func press(_ code: UInt16) {
        guard keys.press(code) else { return }
        if Modifiers.isModifier(code) {
            sink.post(.flagsChanged(code: code, flags: keyFlags(keys.modifierFlags)))
        } else {
            sink.post(.key(code: code, down: true, flags: keyFlags(keys.modifierFlags | implicitFlags(code)), autorepeat: false, text: nil))
        }
    }

    private func release(_ code: UInt16) {
        guard keys.release(code) else { return }
        if Modifiers.isModifier(code) {
            sink.post(.flagsChanged(code: code, flags: keyFlags(keys.modifierFlags)))
        } else {
            sink.post(.key(code: code, down: false, flags: keyFlags(keys.modifierFlags | implicitFlags(code)), autorepeat: false, text: nil))
        }
    }

    private func pressTemp(_ mods: UInt16) -> [UInt16] {
        let temps = keys.missingTemps(mods)
        for code in temps { press(code) }
        if !temps.isEmpty { clock.sleep(EngineConstants.modifierPause) }
        return temps
    }

    private func releaseTemp(_ temps: [UInt16]) {
        guard !temps.isEmpty else { return }
        clock.sleep(EngineConstants.modifierPause)
        for code in temps.reversed() { release(code) }
    }

    private func tap(_ code: UInt16, mods: UInt16, hold: Double) {
        if code == KeyCode.capsLock {
            toggleCapsLock()
            return
        }
        cancelRepeat()
        let temps = Modifiers.isModifier(code) ? [] : pressTemp(mods)
        press(code)
        clock.sleep(hold)
        release(code)
        releaseTemp(temps)
    }

    private func typeKey(_ code: UInt16, mods: UInt16) {
        if keys.isDown(code) || Modifiers.isModifier(code) {
            tap(code, mods: mods, hold: EngineConstants.typeHold)
            return
        }
        cancelRepeat()
        let temps = pressTemp(mods)
        let flags = keyFlags(implicitFlags(code) | keys.modifierFlags(limitedTo: mods))
        sink.post(.key(code: code, down: true, flags: flags, autorepeat: false, text: nil))
        clock.sleep(EngineConstants.typeHold)
        sink.post(.key(code: code, down: false, flags: flags, autorepeat: false, text: nil))
        releaseTemp(temps)
    }

    private func keyDown(_ code: UInt16, mods: UInt16, repeats: Bool, session: UInt64) {
        if code == KeyCode.capsLock {
            toggleCapsLock()
            return
        }
        guard var st = sessions[session], !st.holds(code) else { return }
        if Modifiers.isModifier(code) {
            st.keys.append((code, []))
            sessions[session] = st
            press(code)
            return
        }
        let temps = pressTemp(mods)
        press(code)
        st.keys.append((code, temps))
        sessions[session] = st
        if repeats {
            let now = clock.now()
            autorepeat = Repeat(code: code, session: session, next: now + timing.repeatDelay, end: now + EngineConstants.repeatLimit)
        } else {
            cancelRepeat()
        }
    }

    private func keyUp(_ code: UInt16, session: UInt64) {
        if code == KeyCode.capsLock { return }
        guard var st = sessions[session], let i = st.keys.firstIndex(where: { $0.code == code }) else { return }
        let temps = st.keys.remove(at: i).temps
        sessions[session] = st
        if let r = autorepeat, r.code == code, r.session == session { autorepeat = nil }
        release(code)
        releaseTemp(temps)
    }

    private func cancelRepeat() { autorepeat = nil }

    private func repeatTick(_ now: Double) {
        guard var r = autorepeat else { return }
        let silent = sessions[r.session].map { now - $0.lastSignal >= EngineConstants.repeatSilence } ?? true
        if now >= r.end || silent || !keys.isDown(r.code) {
            autorepeat = nil
            return
        }
        sink.post(.key(code: r.code, down: true, flags: keyFlags(keys.modifierFlags | implicitFlags(r.code)), autorepeat: true, text: nil))
        let interval = timing.repeatInterval
        r.next = now - r.next > 3 * interval ? now + interval : r.next + interval
        autorepeat = r
    }

    // MARK: Media (SPEC §10.9)

    private func media(_ key: MediaKey, op: PressOp, session: UInt64) {
        guard var st = sessions[session] else { return }
        let held = st.media.contains(key)
        switch op {
        case .down:
            guard !held else { return }
            st.media.append(key)
            sessions[session] = st
            sink.post(.media(key, down: true))
        case .up:
            guard held else { return }
            st.media.removeAll { $0 == key }
            sessions[session] = st
            sink.post(.media(key, down: false))
        case .click:
            guard !held else { return }
            sink.post(.media(key, down: true))
            sink.post(.media(key, down: false))
        }
    }

    // MARK: Text (SPEC §11)

    private func type(_ text: String, keystrokes: Bool, session: UInt64) {
        cancelRepeat()
        for (i, segment) in textSegments(text).enumerated() {
            if shouldStop(session) { return }
            if i > 0 { clock.sleep(EngineConstants.segmentPause) }
            switch segment {
            case .newline: typeKey(KeyCode.returnKey, mods: 0)
            case .tab: typeKey(KeyCode.tab, mods: 0)
            case let .text(run):
                if keystrokes {
                    typeKeystrokes(run, session: session)
                } else {
                    postUnicode(run)
                }
            }
        }
    }

    private func typeKeystrokes(_ run: String, session: UInt64) {
        var pending = ""
        for ch in run {
            if shouldStop(session) { return }
            if let stroke = charMap[ch] {
                if !pending.isEmpty {
                    postUnicode(pending)
                    pending = ""
                }
                typeKey(stroke.code, mods: stroke.mods)
            } else {
                pending.append(ch)
            }
        }
        if !pending.isEmpty { postUnicode(pending) }
    }

    private func postUnicode(_ run: String) {
        sink.post(.key(code: KeyCode.unicodeCarrier, down: true, flags: KeyFlags.nonCoalesced, autorepeat: false, text: run))
        sink.post(.key(code: KeyCode.unicodeCarrier, down: false, flags: KeyFlags.nonCoalesced, autorepeat: false, text: nil))
    }

    private func edit(delete: Int, insert: String, session: UInt64) {
        cancelRepeat()
        for _ in 0..<min(max(delete, 0), TextLimits.maxDeletes) {
            if shouldStop(session) { return }
            typeKey(KeyCode.delete, mods: 0)
        }
        if !insert.isEmpty { type(insert, keystrokes: false, session: session) }
    }

    // MARK: Watchdog and release (SPEC §10.10)

    private func armWatchdog() {
        if watchdogNext == nil, sessions.values.contains(where: \.holdsSomething) {
            watchdogNext = clock.now() + EngineConstants.watchdogPeriod
        }
    }

    private func watchdogTick(_ now: Double) {
        for (id, st) in sessions.sorted(by: { $0.key < $1.key }) where st.holdsSomething {
            if Int(now - st.lastSignal) > EngineConstants.watchdogSilence {
                releaseSession(id)
            }
        }
        watchdogNext = sessions.values.contains(where: \.holdsSomething) ? now + EngineConstants.watchdogPeriod : nil
    }

    /// Keys (latest first, each with its temporaries), then buttons, then media.
    private func releaseSession(_ session: UInt64) {
        if let r = autorepeat, r.session == session { autorepeat = nil }
        guard var st = sessions[session] else { return }
        let held = st
        st.keys = []
        st.buttons = []
        st.media = []
        sessions[session] = st
        for k in held.keys.reversed() {
            release(k.code)
            releaseTemp(k.temps)
        }
        for b in held.buttons { releaseButton(b) }
        for m in held.media { sink.post(.media(m, down: false)) }
    }

    private func releaseAll() {
        autorepeat = nil
        for id in sessions.keys.sorted() { releaseSession(id) }
        watchdogNext = nil
    }
}

extension Input {
    /// Inputs that type (SPEC §10.2 step 5).
    var isTyping: Bool {
        switch self {
        case let .key(_, down, _, _): down
        case .tap, .tapChar, .text, .edit: true
        default: false
        }
    }
}
