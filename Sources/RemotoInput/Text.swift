// Text segmentation and the layout character map (SPEC §11.2, §11.3).

enum TextLimits {
    static let segmentUnits = 16
    static let maxDeletes = 4096
}

enum TextSegment: Equatable {
    case text(String)
    case newline
    case tab
}

/// Splits text into runs of at most 16 UTF-16 units, newlines and tabs.
/// `\r\n` is one newline; other C0 controls and 0x7F–0x9F are dropped.
func textSegments(_ s: String) -> [TextSegment] {
    var out: [TextSegment] = []
    var run = String.UnicodeScalarView()
    var units = 0

    func flush() {
        if !run.isEmpty {
            out.append(.text(String(run)))
            run = String.UnicodeScalarView()
            units = 0
        }
    }

    var previousWasCR = false
    for scalar in s.unicodeScalars {
        let v = scalar.value
        defer { previousWasCR = v == 0x0D }
        switch v {
        case 0x09:
            flush()
            out.append(.tab)
        case 0x0D:
            flush()
            out.append(.newline)
        case 0x0A:
            if previousWasCR { continue }
            flush()
            out.append(.newline)
        case 0..<0x20, 0x7F...0x9F:
            continue
        default:
            let n = scalar.utf16.count
            if units + n > TextLimits.segmentUnits { flush() }
            run.append(scalar)
            units += n
        }
    }
    flush()
    return out
}

/// A key and the wire modifiers that type a character.
struct KeyStroke: Equatable {
    var code: UInt16
    var mods: UInt16
}

/// Characters a layout can type directly (SPEC §11.3).
struct CharacterMap {
    private(set) var strokes: [Character: KeyStroke] = [:]

    init() {}

    init(_ layout: KeyboardLayout?) {
        guard let layout else { return }
        for key in layout.keys {
            let levels: [(String, UInt16, UInt8)] = [
                (key.optionShift, WireMods.option | WireMods.shift, 1 << 3),
                (key.option, WireMods.option, 1 << 2),
                (key.shift, WireMods.shift, 1 << 1),
                (key.base, 0, 1 << 0),
            ]
            for (string, mods, deadBit) in levels {
                if key.dead & deadBit != 0 { continue }
                guard let ch = Self.printableCharacter(string) else { continue }
                let stroke = KeyStroke(code: key.code, mods: mods)
                if let existing = strokes[ch], existing.mods.nonzeroBitCount <= mods.nonzeroBitCount { continue }
                strokes[ch] = stroke
            }
        }
    }

    subscript(_ ch: Character) -> KeyStroke? { strokes[ch] }

    var isEmpty: Bool { strokes.isEmpty }

    /// Keycode of `ch` on the level without modifiers, if the layout has it there.
    func baseCode(_ ch: Character) -> UInt16? {
        guard let s = strokes[ch], s.mods == 0 else { return nil }
        return s.code
    }

    /// The string if it is exactly one printable character.
    static func printableCharacter(_ s: String) -> Character? {
        guard s.count == 1, let ch = s.first else { return nil }
        for scalar in ch.unicodeScalars {
            let v = scalar.value
            if v < 0x20 || (0x7F...0x9F).contains(v) { return nil }
        }
        return ch
    }
}
