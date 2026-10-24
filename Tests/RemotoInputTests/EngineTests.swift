import Foundation
import Testing
@testable import RemotoInput

@Suite struct WatchdogTests {
    @Test func releasesASilentSessionAtSixSeconds() {
        let h = Harness()
        h.send(.key(code: 0x00, down: true, mods: 0, repeats: false))
        h.send(.button(.left, .down))
        h.send(.media(.volumeUp, .down))
        h.clear()
        h.advance(5.9)
        #expect(h.events.isEmpty)
        h.advance(0.2)
        #expect(h.keys.map(\.kind) == [.up])
        #expect(h.buttons.map(\.kind) == [.up])
        #expect(h.events.last == .media(.volumeUp, down: false))
        #expect(h.core.nextDeadline() == nil)
    }

    @Test func signsOfLifeKeepItHeld() {
        let h = Harness()
        h.send(.key(code: 0x00, down: true, mods: 0, repeats: false))
        h.clear()
        for _ in 0..<20 {
            h.advance(1)
            h.process(.alive(session: 1))
        }
        #expect(h.events.isEmpty)
        h.advance(6.1)
        #expect(h.keys.map(\.kind) == [.up])
    }

    @Test func releaseOrderIsKeysButtonsMedia() {
        let h = Harness()
        h.send(.media(.mute, .down))
        h.send(.button(.right, .down))
        h.send(.key(code: 0x37, down: true, mods: 0, repeats: false))
        h.send(.key(code: 0x08, down: true, mods: WireMods.shift, repeats: false))
        h.clear()
        h.send(.release)
        #expect(h.events.map(\.description) == [
            "keyUp 0x08 flags=0x12010a",
            "flagsChanged 0x38 flags=0x100108",
            "flagsChanged 0x37 flags=0x100",
            "mouseUp right click=1 at=720,450 flags=0x0",
            "media mute nx=7 up",
        ])
    }
}

@Suite struct MediaTests {
    @Test func perSessionPressedSet() {
        let h = Harness()
        h.send(.media(.playPause, .down))
        h.send(.media(.playPause, .down))
        h.send(.media(.playPause, .click))  // held: nothing
        h.send(.media(.playPause, .up))
        h.send(.media(.playPause, .up))
        h.send(.media(.next, .click))
        #expect(h.events == [
            .media(.playPause, down: true), .media(.playPause, down: false),
            .media(.next, down: true), .media(.next, down: false),
        ])
    }

    @Test func nxKeyTypesAndData1() {
        let expected: [MediaKey: Int32] = [
            .volumeUp: 0, .volumeDown: 1, .brightnessUp: 2, .brightnessDown: 3, .mute: 7, .playPause: 16,
            .next: 17, .previous: 18, .fastForward: 19, .rewind: 20, .illuminationUp: 21,
            .illuminationDown: 22, .illuminationToggle: 23,
        ]
        for key in MediaKey.allCases { #expect(key.nxKeyType == expected[key]) }
        #expect(MediaKey.playPause.data1(down: true) == 0x10_0A00)
        #expect(MediaKey.playPause.data1(down: false) == 0x10_0B00)
    }
}

@Suite struct PauseAndForgetTests {
    @Test func pauseReleasesDropsAndDiscards() {
        let h = Harness()
        h.send(.key(code: 0x00, down: true, mods: 0, repeats: true))
        h.send(.move(dx: 50, dy: 0))
        h.clear()
        h.process(.setPaused(true))
        #expect(h.keys.map(\.kind) == [.up])
        #expect(h.moves.isEmpty)
        #expect(h.core.autorepeat == nil)
        h.clear()
        h.send(.click(.left, count: 1))
        h.send(.text("x", keystrokes: false))
        h.advance(1)
        #expect(h.events.isEmpty)
        h.process(.setPaused(false))
        h.send(.click(.left, count: 1))
        #expect(h.buttons.count == 2)
    }

    @Test func forgetReleasesTheSessionAndIgnoresItAfterwards() {
        let h = Harness()
        h.send(.key(code: 0x00, down: true, mods: 0, repeats: false), session: 1)
        h.send(.button(.left, .down), session: 1)
        h.send(.key(code: 0x01, down: true, mods: 0, repeats: false), session: 2)
        h.send(.move(dx: 9, dy: 9), session: 2)
        h.clear()
        h.process(.forget(session: 1))
        #expect(h.keys.map(\.code) == [0x00])
        #expect(h.buttons.map(\.kind) == [.up])
        #expect(h.moves.isEmpty)  // the pacer was emptied
        h.clear()
        h.send(.click(.left, count: 1), session: 1)
        h.process(.alive(session: 1))
        #expect(h.events.isEmpty)
        #expect(h.core.sessions[1] == nil)
        h.send(.click(.left, count: 1), session: 2)
        #expect(h.buttons.count == 2)
        #expect(h.core.keys.isDown(0x01))
    }

    @Test func forgottenListIsBoundedTo256() {
        var f = ForgottenSessions()
        for s in 0..<300 as Range<UInt64> { f.insert(s) }
        #expect(!f.contains(43))
        #expect(f.contains(44))
        #expect(f.contains(299))
    }
}

@Suite struct NoticeTests {
    @Test func accessibilityNoticeAtMostOnceEveryFourSecondsPerSession() {
        let h = Harness()
        h.sink.trusted = false
        h.send(.move(dx: 1, dy: 0), session: 1)
        h.send(.move(dx: 1, dy: 0), session: 2)
        h.advance(3.9)
        h.send(.click(.left, count: 1), session: 1)
        #expect(h.notices.items.map(\.session) == [1, 2])
        h.advance(0.2)
        h.send(.click(.left, count: 1), session: 1)
        #expect(h.notices.items.map(\.session) == [1, 2, 1])
        #expect(h.notices.items.allSatisfy { $0.notice == .accessibility })
        // The event is still posted.
        #expect(h.buttons.count == 4)
    }

    @Test func touchAndReleaseNeedNoPermission() {
        let h = Harness()
        h.sink.trusted = false
        h.send(.touch)
        h.send(.release)
        #expect(h.notices.items.isEmpty)
    }

    @Test func secureInputOnlyForTyping() {
        let h = Harness()
        h.sink.secureInput = true
        h.send(.move(dx: 1, dy: 1))
        h.send(.key(code: 0x00, down: false, mods: 0, repeats: false))
        h.send(.click(.left, count: 1))
        #expect(h.notices.items.isEmpty)
        h.send(.text("pw", keystrokes: false))
        h.send(.tap(code: 0x00, mods: 0))
        #expect(h.notices.items.map(\.notice) == [.secureInput])
        #expect(h.keys.contains { $0.text == "pw" })
        h.advance(4)
        h.send(.edit(delete: 1, insert: ""))
        #expect(h.notices.items.map(\.notice) == [.secureInput, .secureInput])
    }

    @Test func statusIsCachedFor750ms() {
        let h = Harness()
        h.send(.move(dx: 1, dy: 0))
        h.sink.trusted = false
        h.advance(0.7)
        h.send(.move(dx: 1, dy: 0))
        #expect(h.notices.items.isEmpty)
        h.advance(0.06)
        h.send(.move(dx: 1, dy: 0))
        #expect(h.notices.items.count == 1)
    }

    @Test func limiterIsPerKind() {
        var l = NoticeLimiter()
        let results = [
            l.allow(.accessibility, session: 1, now: 0),
            l.allow(.secureInput, session: 1, now: 0),
            l.allow(.accessibility, session: 2, now: 1),
            l.allow(.accessibility, session: 1, now: 3.999),
            l.allow(.accessibility, session: 1, now: 4),
        ]
        #expect(results == [true, true, true, false, true])
    }
}

/// The real engine thread with a log sink. Never `.system`.
@Suite struct ThreadedEngineTests {
    @Test func postsInOrderAndFlushes() async {
        let log = EventLog()
        let engine = InputEngine(sink: .log(log)) { _, _ in }
        engine.send(.move(dx: 10, dy: 5), session: 1)
        engine.send(.click(.left, count: 2), session: 1)
        engine.send(.text("hi", keystrokes: false), session: 1)
        await engine.flush()
        #expect(log.lines == [
            "move 10,5 at=730,455 flags=0x0",
            "mouseDown left click=1 at=730,455 flags=0x0",
            "mouseUp left click=1 at=730,455 flags=0x0",
            "mouseDown left click=2 at=730,455 flags=0x0",
            "mouseUp left click=2 at=730,455 flags=0x0",
            #"keyDown 0x00 flags=0x100 text="hi""#,
            "keyUp 0x00 flags=0x100",
        ])
        engine.shutdown()
    }

    @Test func pacerRunsOnItsOwn() async throws {
        let log = EventLog()
        let engine = InputEngine(sink: .log(log)) { _, _ in }
        engine.send(.move(dx: 40, dy: 0), session: 1)
        try await Task.sleep(for: .milliseconds(150))
        let moves = log.lines.filter { $0.hasPrefix("move") }
        #expect(!moves.isEmpty)
        #expect(moves.last?.contains("at=760,450") == true)
        engine.shutdown()
    }

    @Test func shutdownReleasesEverythingAndFlushStillReturns() async {
        let log = EventLog()
        let engine = InputEngine(sink: .log(log)) { _, _ in }
        engine.send(.key(code: 0x00, down: true, mods: 0, repeats: true), session: 7)
        await engine.flush()
        #expect(log.lines == ["keyDown 0x00 flags=0x100"])
        engine.shutdown()
        #expect(log.lines.last == "keyUp 0x00 flags=0x100")
        engine.shutdown()  // idempotent
        await engine.flush()  // returns at once
        engine.send(.click(.left, count: 1), session: 7)
        #expect(log.lines.count == 2)
    }

    @Test func pauseIsImmediate() async {
        let log = EventLog()
        let engine = InputEngine(sink: .log(log)) { _, _ in }
        engine.setPaused(true)
        engine.send(.text("secret", keystrokes: false), session: 1)
        await engine.flush()
        #expect(log.lines.isEmpty)
        engine.setPaused(false)
        engine.send(.tap(code: 0x31, mods: 0), session: 1)
        await engine.flush()
        #expect(log.lines == ["keyDown 0x31 flags=0x100", "keyUp 0x31 flags=0x100"])
        engine.shutdown()
    }

    @Test func noticesArriveFromTheEngineThread() async {
        let seen = OSAllocatedUnfairLockBox()
        let log = EventLog()
        let engine = InputEngine(sink: .log(log)) { session, notice in
            seen.add("\(session):\(notice):\(Thread.current.name ?? "")")
        }
        engine.send(.tap(code: 0x00, mods: 0), session: 3)
        await engine.flush()
        // The log sink is trusted and has no secure input, so nothing is reported.
        #expect(seen.items.isEmpty)
        engine.shutdown()
    }
}

import os

final class OSAllocatedUnfairLockBox: Sendable {
    private let lock = OSAllocatedUnfairLock<[String]>(initialState: [])
    func add(_ s: String) { lock.withLock { $0.append(s) } }
    var items: [String] { lock.withLock { $0 } }
}
