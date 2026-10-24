import Testing
@testable import RemotoInput

@Suite struct SegmentationTests {
    @Test func shortTextIsOneSegment() {
        #expect(textSegments("hola") == [.text("hola")])
        #expect(textSegments("") == [])
    }

    @Test func cutsAtSixteenUTF16Units() {
        let s = String(repeating: "a", count: 20)
        #expect(textSegments(s) == [.text(String(repeating: "a", count: 16)), .text("aaaa")])
        #expect(textSegments(String(repeating: "b", count: 32)).count == 2)
    }

    @Test func astralCharactersCountTwo() {
        let fits = String(repeating: "a", count: 14) + "😀"
        #expect(textSegments(fits) == [.text(fits)])
        let over = String(repeating: "a", count: 15) + "😀"
        #expect(textSegments(over) == [.text(String(repeating: "a", count: 15)), .text("😀")])
        let emoji = String(repeating: "😀", count: 9)
        #expect(textSegments(emoji) == [.text(String(repeating: "😀", count: 8)), .text("😀")])
    }

    @Test func newlinesAndTabs() {
        #expect(textSegments("a\r\nb\rc\nd\te") == [
            .text("a"), .newline, .text("b"), .newline, .text("c"), .newline, .text("d"), .tab, .text("e"),
        ])
        #expect(textSegments("\r\n\n") == [.newline, .newline])
        #expect(textSegments("\n\r") == [.newline, .newline])
        #expect(textSegments("\t\t") == [.tab, .tab])
    }

    @Test func controlsAreDropped() {
        #expect(textSegments("a\u{0}b\u{1B}c\u{7F}d\u{85}e\u{9F}f\u{A0}") == [.text("abcdef\u{A0}")])
        #expect(textSegments("\u{1}\u{2}") == [])
    }
}

@Suite struct CharacterMapTests {
    private func key(_ code: UInt16, _ base: String, _ shift: String = "", _ option: String = "", _ optionShift: String = "", dead: UInt8 = 0) -> KeyCap {
        KeyCap(code: code, base: base, shift: shift, option: option, optionShift: optionShift, dead: dead)
    }

    @Test func levelsCarryTheirModifiers() {
        let map = CharacterMap(KeyboardLayout(id: "x", name: "x", iso: false, keys: [key(0, "a", "A", "å", "Å")]))
        #expect(map["a"] == KeyStroke(code: 0, mods: 0))
        #expect(map["A"] == KeyStroke(code: 0, mods: WireMods.shift))
        #expect(map["å"] == KeyStroke(code: 0, mods: WireMods.option))
        #expect(map["Å"] == KeyStroke(code: 0, mods: WireMods.option | WireMods.shift))
    }

    @Test func fewerModifierBitsWinAndTiesKeepTheFirst() {
        let map = CharacterMap(
            KeyboardLayout(
                id: "x", name: "x", iso: false,
                keys: [
                    key(5, "", "", "x"),  // option x
                    key(6, "x"),  // base x: fewer bits, replaces
                    key(7, "", "y"),  // shift y
                    key(8, "", "", "y"),  // option y: tie, first stays
                    key(9, "", "", "", "z"),  // option+shift z
                    key(10, "", "z"),  // shift z: fewer bits, replaces
                    key(11, "q", "", "", "q"),  // same key: base beats option+shift
                    key(12, "w"),
                    key(13, "w"),  // tie at base: first stays
                ]))
        #expect(map["x"] == KeyStroke(code: 6, mods: 0))
        #expect(map["y"] == KeyStroke(code: 7, mods: WireMods.shift))
        #expect(map["z"] == KeyStroke(code: 10, mods: WireMods.shift))
        #expect(map["q"] == KeyStroke(code: 11, mods: 0))
        #expect(map["w"] == KeyStroke(code: 12, mods: 0))
    }

    @Test func deadAndUnprintableLevelsAreSkipped() {
        let map = CharacterMap(
            KeyboardLayout(
                id: "x", name: "x", iso: false,
                keys: [
                    key(1, "´", "¨", "e", "", dead: 0b0011),
                    key(2, "\u{7F}", "ab", "\u{85}", "\r\n"),
                    key(3, "é"),
                ]))
        #expect(map["´"] == nil)
        #expect(map["¨"] == nil)
        #expect(map["e"] == KeyStroke(code: 1, mods: WireMods.option))
        #expect(map["\u{7F}"] == nil)
        #expect(map["\u{85}"] == nil)
        #expect(map["é"] == KeyStroke(code: 3, mods: 0))
        #expect(map.strokes.count == 2)
        #expect(CharacterMap(nil).isEmpty)
    }
}

@Suite struct TypingTests {
    @Test func unicodeTextGoesOnKeycodeZero() {
        let h = Harness()
        h.send(.text("hola", keystrokes: false))
        #expect(h.keys == [
            KeyRecord(code: 0, kind: .down, flags: 0x100, autorepeat: false, text: "hola"),
            KeyRecord(code: 0, kind: .up, flags: 0x100, autorepeat: false, text: nil),
        ])
        #expect(h.log.lines == [#"keyDown 0x00 flags=0x100 text="hola""#, "keyUp 0x00 flags=0x100"])
    }

    @Test func newlineAndTabAreKeysAndSegmentsArePaced() {
        let h = Harness()
        h.send(.key(code: 0x37, down: true, mods: 0, repeats: false))  // Cmd held by the user
        h.clear()
        let t0 = h.now
        h.send(.text("a\nb\tc", keystrokes: false))
        let downs = h.keys.filter { $0.kind == .down }
        #expect(downs.map(\.code) == [0x00, 0x24, 0x00, 0x30, 0x00])
        // Typing ignores held modifiers that are not in `mods`.
        #expect(downs[1].flags == 0x100)
        #expect(downs[3].flags == 0x100)
        // 4 pauses of 2 ms between 5 segments, plus 2 ms holds for Return and Tab.
        #expect(approx(h.now - t0, 0.012))
    }

    @Test func keystrokesUseTheLayoutMap() {
        let h = Harness()
        h.process(.setLayout(KeyboardLayout(id: "us", name: "US", iso: false, keys: [
            KeyCap(code: 0x00, base: "a", shift: "A", option: "", optionShift: "", dead: 0),
        ])))
        h.send(.text("éaAñ", keystrokes: true))
        let k = h.keys
        #expect(k.map(\.code) == [0x00, 0x00, 0x00, 0x00, 0x38, 0x00, 0x00, 0x38, 0x00, 0x00])
        #expect(k[0].text == "é")
        #expect(k[2].text == nil && k[2].kind == .down)
        #expect(k[5].flags == 0x20102)  // shift from mods
        #expect(k[8].text == "ñ")
    }

    @Test func editDeletesAtMost4096ThenInserts() {
        let h = Harness()
        h.send(.edit(delete: 10_000, insert: "ok"))
        let deletes = h.keys.filter { $0.code == 0x33 && $0.kind == .down }
        #expect(deletes.count == 4096)
        #expect(h.keys.last == KeyRecord(code: 0, kind: .up, flags: 0x100, autorepeat: false))
        #expect(h.keys.dropLast().last?.text == "ok")

        h.clear()
        h.send(.edit(delete: -3, insert: ""))
        #expect(h.keys.isEmpty)
        h.send(.edit(delete: 2, insert: ""))
        #expect(h.keys.map(\.code) == [0x33, 0x33, 0x33, 0x33])
    }

    @Test func textStopsWhenTheSessionIsGone() {
        let h = Harness()
        h.core.stop.forget(1)  // as InputEngine.forget does before the command is processed
        h.send(.text("never", keystrokes: false))
        #expect(h.keys.isEmpty)
    }
}
