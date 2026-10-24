import Testing
@testable import RemotoInput

private let all: UInt16 = WireMods.command | WireMods.shift | WireMods.option | WireMods.control | WireMods.fn

@Suite struct ModifierTests {
    @Test func temporaryModifiersPressInOrderAndReleaseInReverse() {
        let h = Harness()
        let t0 = h.now
        h.send(.tap(code: 0x00, mods: all))
        let k = h.keys
        #expect(k.map(\.code) == [0x3B, 0x3A, 0x38, 0x37, 0x3F, 0x00, 0x00, 0x3F, 0x37, 0x38, 0x3A, 0x3B])
        #expect(k.map(\.kind) == [.flags, .flags, .flags, .flags, .flags, .down, .up, .flags, .flags, .flags, .flags, .flags])
        #expect(k.map(\.flags) == [
            0x40101, 0xC0121, 0xE0123, 0x1E012B, 0x9E012B,
            0x9E012B, 0x9E012B,
            0x1E012B, 0xE0123, 0xC0121, 0x40101, 0x100,
        ])
        // 8 ms after the modifiers, 12 ms hold, 8 ms before letting them go.
        #expect(approx(h.now - t0, 0.028))
        #expect(h.core.keys.counts.isEmpty)
    }

    @Test func tapWithoutModifiersOnlyHolds() {
        let h = Harness()
        let t0 = h.now
        h.send(.tap(code: 0x0E, mods: 0))
        #expect(h.keys.map(\.kind) == [.down, .up])
        #expect(h.keys.map(\.flags) == [0x100, 0x100])
        #expect(approx(h.now - t0, 0.012))
    }

    @Test func heldModifiersAreSkipped() {
        let h = Harness()
        h.send(.key(code: 0x3C, down: true, mods: 0, repeats: false))  // right shift held
        h.clear()
        h.send(.tap(code: 0x01, mods: WireMods.shift | WireMods.command))
        // Generic Shift is already there, so only Cmd is pressed.
        #expect(h.keys.map(\.code) == [0x37, 0x01, 0x01, 0x37])
        #expect(h.keys[1].flags == 0x100000 | 0x08 | 0x20000 | 0x04 | 0x100)

        h.clear()
        // A right-side bit only looks at that exact key: left Shift held does not cover right Shift.
        h.send(.key(code: 0x3C, down: false, mods: 0, repeats: false))
        h.send(.key(code: 0x38, down: true, mods: 0, repeats: false))
        h.clear()
        h.send(.tap(code: 0x01, mods: WireMods.rightShift))
        #expect(h.keys.map(\.code) == [0x3C, 0x01, 0x01, 0x3C])
        h.clear()
        h.send(.tap(code: 0x01, mods: WireMods.shift))
        #expect(h.keys.map(\.code) == [0x01, 0x01])
    }

    @Test func modifierFlagsAreGenericPlusSide() {
        let h = Harness()
        let expected: [(UInt16, UInt64)] = [
            (0x37, 0x100008), (0x36, 0x100010), (0x38, 0x20002), (0x3C, 0x20004),
            (0x3A, 0x80020), (0x3D, 0x80040), (0x3B, 0x40001), (0x3E, 0x42000), (0x3F, 0x800000),
        ]
        for (code, mask) in expected {
            h.clear()
            h.send(.key(code: code, down: true, mods: 0, repeats: true))
            h.send(.key(code: code, down: false, mods: 0, repeats: false))
            #expect(h.keys == [
                KeyRecord(code: code, kind: .flags, flags: mask | 0x100, autorepeat: false),
                KeyRecord(code: code, kind: .flags, flags: 0x100, autorepeat: false),
            ])
        }
        #expect(h.core.autorepeat == nil)  // modifiers never repeat
    }

    @Test func implicitFlagsByKeycode() {
        #expect(implicitFlags(0x7B) == 0xA00000)
        #expect(implicitFlags(0x7E) == 0xA00000)
        for code: UInt16 in [0x40, 0x4F, 0x50, 0x5A, 0x60, 0x65, 0x67, 0x69, 0x6B, 0x6D, 0x6F, 0x71, 0x7A] {
            #expect(implicitFlags(code) == 0x800000)
        }
        for code: UInt16 in [0x41, 0x43, 0x45, 0x47, 0x4B, 0x4C, 0x4E, 0x51, 0x59, 0x5B, 0x5C] {
            #expect(implicitFlags(code) == 0x200000)
        }
        for code: UInt16 in [0x00, 0x24, 0x31, 0x66, 0x68, 0x6C, 0x6E, 0x70, 0x5D, 0x42, 0x7F] {
            #expect(implicitFlags(code) == 0)
        }

        let h = Harness()
        h.send(.tap(code: 0x7B, mods: 0))
        h.send(.tap(code: 0x7A, mods: 0))
        h.send(.tap(code: 0x41, mods: 0))
        #expect(h.keys.map(\.flags) == [0xA00100, 0xA00100, 0x800100, 0x800100, 0x200100, 0x200100])
    }

    @Test func capsLockTogglesAndShowsInFlags() {
        let h = Harness()
        h.send(.key(code: 0x39, down: true, mods: 0, repeats: true))
        h.send(.key(code: 0x39, down: false, mods: 0, repeats: false))
        #expect(h.events == [.capsLock(on: true)])
        h.send(.tap(code: 0x00, mods: 0))
        #expect(h.keys.map(\.flags) == [0x10100, 0x10100])
        h.clear()
        h.send(.tap(code: 0x39, mods: WireMods.command))  // only the toggle
        #expect(h.events == [.capsLock(on: false)])
    }
}

@Suite struct KeyRefcountTests {
    @Test func keysAreRefcountedAcrossSessions() {
        let h = Harness()
        h.send(.key(code: 0x00, down: true, mods: 0, repeats: false), session: 1)
        h.send(.key(code: 0x00, down: true, mods: 0, repeats: false), session: 1)  // same session: ignored
        h.send(.key(code: 0x00, down: true, mods: 0, repeats: false), session: 2)
        #expect(h.keys.map(\.kind) == [.down])
        h.send(.key(code: 0x00, down: false, mods: 0, repeats: false), session: 1)
        h.send(.key(code: 0x00, down: false, mods: 0, repeats: false), session: 1)
        #expect(h.keys.count == 1)
        h.send(.key(code: 0x00, down: false, mods: 0, repeats: false), session: 2)
        #expect(h.keys.map(\.kind) == [.down, .up])
    }

    @Test func keyMessageKeepsItsTemporaries() {
        let h = Harness()
        h.send(.key(code: 0x08, down: true, mods: WireMods.command, repeats: false))
        #expect(h.keys.map(\.code) == [0x37, 0x08])
        let t0 = h.now
        h.send(.key(code: 0x08, down: false, mods: 0, repeats: false))
        #expect(h.keys.map(\.code) == [0x37, 0x08, 0x08, 0x37])
        #expect(approx(h.now - t0, 0.008))
    }

    @Test func tapOfAHeldKeyPostsNothing() {
        let h = Harness()
        h.send(.key(code: 0x00, down: true, mods: 0, repeats: false))
        h.send(.tap(code: 0x00, mods: 0))
        #expect(h.keys.map(\.kind) == [.down])
        #expect(h.core.keys.counts[0x00] == 1)
    }

    @Test func pureRefcount() {
        var r = KeyRefcount()
        let results = [r.press(0x37), r.press(0x37), r.release(0x37), r.release(0x37), r.release(0x37)]
        #expect(results == [true, false, false, true, false])
        #expect(r.modifierFlags == 0)
    }

    @Test func tapCharUsesTheLayoutBaseLevel() {
        let h = Harness()
        let azerty = KeyboardLayout(
            id: "fr", name: "French", iso: true,
            keys: [
                KeyCap(code: 0x0C, base: "a", shift: "A", option: "æ", optionShift: "Æ", dead: 0),
                KeyCap(code: 0x00, base: "q", shift: "Q", option: "‡", optionShift: "Ω", dead: 0),
                KeyCap(code: 0x2B, base: ";", shift: "w", option: "", optionShift: "", dead: 0),
            ])
        h.send(.tapChar(code: 0x00, mods: WireMods.command, char: "A"))
        #expect(h.keys.filter { $0.kind == .down }.map(\.code) == [0x00])  // no layout yet: fallback
        h.process(.setLayout(azerty))
        h.clear()
        h.send(.tapChar(code: 0x00, mods: WireMods.command, char: "A"))
        #expect(h.keys.map(\.code) == [0x37, 0x0C, 0x0C, 0x37])
        h.clear()
        h.send(.tapChar(code: 0x0D, mods: WireMods.command, char: "w"))  // only on shift: fallback
        #expect(h.keys.filter { $0.kind == .down }.map(\.code) == [0x0D])
    }
}

@Suite struct AutorepeatTests {
    private func repeats(_ h: Harness) -> Int { h.keys.filter(\.autorepeat).count }

    @Test func delayThenInterval() {
        let h = Harness()
        h.send(.key(code: 0x04, down: true, mods: 0, repeats: true))
        h.advance(0.499)
        #expect(repeats(h) == 0)
        h.advance(0.002)
        #expect(repeats(h) == 1)
        h.advance(0.080)
        #expect(repeats(h) == 1)
        h.advance(0.004)
        #expect(repeats(h) == 2)
        #expect(h.keys.last == KeyRecord(code: 0x04, kind: .down, flags: 0x100, autorepeat: true))
        h.send(.key(code: 0x04, down: false, mods: 0, repeats: false))
        h.advance(1)
        #expect(repeats(h) == 2)
    }

    @Test func timingIsClamped() {
        let h = Harness()
        h.process(.setTiming(InputTiming(repeatDelayMs: 10, repeatIntervalMs: 1, doubleClickMs: 99_999)))
        #expect(h.core.timing.repeatDelay == 0.1)
        #expect(h.core.timing.repeatInterval == 0.015)
        #expect(h.core.timing.doubleClick == 5)
        h.process(.setTiming(InputTiming(repeatDelayMs: 9000, repeatIntervalMs: 9000, doubleClickMs: 1)))
        #expect(h.core.timing.repeatDelay == 3)
        #expect(h.core.timing.repeatInterval == 2)
        #expect(h.core.timing.doubleClick == 0.15)
        #expect(EngineTiming() == EngineTiming(InputTiming()))
    }

    @Test func stopsAtSixtySeconds() {
        let h = Harness()
        let t0 = h.now
        h.send(.key(code: 0x04, down: true, mods: 0, repeats: true))
        for _ in 0..<60 {
            h.advance(1)
            h.process(.alive(session: 1))
        }
        h.advance(0.5)
        let atEnd = repeats(h)
        #expect(atEnd == Int((59.5 / 0.083).rounded(.down)) + 1)
        #expect(h.core.autorepeat == nil)
        h.advance(3)
        h.process(.alive(session: 1))
        #expect(repeats(h) == atEnd)
        #expect(h.now - t0 > 60)
    }

    @Test func stopsWhenTheOwnerIsSilentForThreeSeconds() {
        let h = Harness()
        h.send(.key(code: 0x04, down: true, mods: 0, repeats: true))
        h.advance(4)
        #expect(repeats(h) == Int((2.5 / 0.083).rounded(.down)) + 1)
        #expect(h.core.autorepeat == nil)
    }

    @Test func lateTickRestartsFromNow() {
        let h = Harness()
        h.send(.key(code: 0x04, down: true, mods: 0, repeats: true))
        let due = h.core.autorepeat!.next
        h.clock.set(due + 0.3)  // more than 3 × 83 ms late
        h.core.runTimers()
        #expect(repeats(h) == 1)
        #expect(approx(h.core.autorepeat!.next, h.now + 0.083))
        h.clock.set(h.core.autorepeat!.next + 0.1)  // late, but not by 3 intervals
        let previous = h.core.autorepeat!.next
        h.core.runTimers()
        #expect(approx(h.core.autorepeat!.next, previous + 0.083))
    }

    @Test func tapAndTextCancelTheRepeat() {
        let h = Harness()
        h.send(.key(code: 0x04, down: true, mods: 0, repeats: true))
        h.send(.tap(code: 0x05, mods: 0))
        #expect(h.core.autorepeat == nil)
        h.send(.key(code: 0x04, down: false, mods: 0, repeats: false))
        h.send(.key(code: 0x04, down: true, mods: 0, repeats: true))
        h.send(.text("x", keystrokes: false))
        #expect(h.core.autorepeat == nil)
        h.send(.key(code: 0x06, down: true, mods: 0, repeats: true))
        h.send(.key(code: 0x07, down: true, mods: 0, repeats: false))  // a key without repeat cancels it
        #expect(h.core.autorepeat == nil)
    }
}
