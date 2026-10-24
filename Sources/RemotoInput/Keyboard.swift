// Keyboard tables and pure keyboard state (SPEC §10.6, §9.5, Appendix B).

enum KeyCode {
    static let returnKey: UInt16 = 0x24
    static let tab: UInt16 = 0x30
    static let delete: UInt16 = 0x33
    static let capsLock: UInt16 = 0x39
    /// Unicode text is posted on keycode 0 (SPEC §11.3).
    static let unicodeCarrier: UInt16 = 0x00
}

enum KeyFlags {
    /// Non-coalesced bit, on every keyboard event.
    static let nonCoalesced: UInt64 = 0x100
    static let capsLock: UInt64 = 0x10000
    /// Media key event flags (down / up), SPEC §10.9.
    static let mediaDown: UInt64 = 0xA00
    static let mediaUp: UInt64 = 0xB00
}

/// Wire modifier bits (SPEC §9.5).
enum WireMods {
    static let command: UInt16 = 0x0001
    static let shift: UInt16 = 0x0002
    static let option: UInt16 = 0x0004
    static let control: UInt16 = 0x0008
    static let fn: UInt16 = 0x0010
    static let rightCommand: UInt16 = 0x0100
    static let rightShift: UInt16 = 0x0200
    static let rightOption: UInt16 = 0x0400
    static let rightControl: UInt16 = 0x0800
}

struct ModifierKey {
    let code: UInt16
    /// Device-independent mask (Command, Shift, ...).
    let generic: UInt64
    /// Side-specific device bits.
    let side: UInt64
    let wire: UInt16
    let isRight: Bool

    var mask: UInt64 { generic | side }
}

enum Modifiers {
    static let keys: [ModifierKey] = [
        ModifierKey(code: 0x37, generic: 0x100000, side: 0x08, wire: WireMods.command, isRight: false),
        ModifierKey(code: 0x36, generic: 0x100000, side: 0x10, wire: WireMods.rightCommand, isRight: true),
        ModifierKey(code: 0x38, generic: 0x20000, side: 0x02, wire: WireMods.shift, isRight: false),
        ModifierKey(code: 0x3C, generic: 0x20000, side: 0x04, wire: WireMods.rightShift, isRight: true),
        ModifierKey(code: 0x3A, generic: 0x80000, side: 0x20, wire: WireMods.option, isRight: false),
        ModifierKey(code: 0x3D, generic: 0x80000, side: 0x40, wire: WireMods.rightOption, isRight: true),
        ModifierKey(code: 0x3B, generic: 0x40000, side: 0x01, wire: WireMods.control, isRight: false),
        ModifierKey(code: 0x3E, generic: 0x40000, side: 0x2000, wire: WireMods.rightControl, isRight: true),
        ModifierKey(code: 0x3F, generic: 0x800000, side: 0, wire: WireMods.fn, isRight: false),
    ]

    private static let byCode: [UInt16: ModifierKey] = Dictionary(uniqueKeysWithValues: keys.map { ($0.code, $0) })
    private static let byWire: [UInt16: ModifierKey] = Dictionary(uniqueKeysWithValues: keys.map { ($0.wire, $0) })

    /// Order in which temporary modifiers are pressed (SPEC §10.6).
    static let tempOrder: [ModifierKey] = [
        WireMods.control, WireMods.rightControl, WireMods.option, WireMods.rightOption,
        WireMods.shift, WireMods.rightShift, WireMods.command, WireMods.rightCommand, WireMods.fn,
    ].map { byWire[$0]! }

    static func key(_ code: UInt16) -> ModifierKey? { byCode[code] }

    /// 0x36–0x3F except CapsLock (SPEC §10.7).
    static func isModifier(_ code: UInt16) -> Bool { byCode[code] != nil }
}

/// Flags every event of this key carries on its own (SPEC §10.6).
func implicitFlags(_ code: UInt16) -> UInt64 {
    switch code {
    case 0x7B...0x7E:
        0xA00000
    case 0x40, 0x4F, 0x50, 0x5A, 0x60...0x65, 0x67, 0x69...0x6B, 0x6D, 0x6F, 0x71...0x7A:
        0x800000
    case 0x41, 0x43, 0x45, 0x47, 0x4B, 0x4C, 0x4E, 0x51...0x59, 0x5B, 0x5C:
        0x200000
    default:
        0
    }
}

/// Global press counts for keys (SPEC §10.6), shared by every session.
struct KeyRefcount {
    private(set) var counts: [UInt16: Int] = [:]

    func isDown(_ code: UInt16) -> Bool { (counts[code] ?? 0) > 0 }

    /// True on 0 → 1 (the press must be posted).
    mutating func press(_ code: UInt16) -> Bool {
        let n = (counts[code] ?? 0) + 1
        counts[code] = n
        return n == 1
    }

    /// True on 1 → 0 (the release must be posted). Releasing an idle key is a no-op.
    mutating func release(_ code: UInt16) -> Bool {
        guard let n = counts[code], n > 0 else { return false }
        if n == 1 {
            counts[code] = nil
            return true
        }
        counts[code] = n - 1
        return false
    }

    /// OR of the masks of every held modifier.
    var modifierFlags: UInt64 {
        var f: UInt64 = 0
        for (code, n) in counts where n > 0 {
            if let m = Modifiers.key(code) { f |= m.mask }
        }
        return f
    }

    /// Masks of the held modifiers whose wire bit is in `mods` (text typing, SPEC §10.6).
    func modifierFlags(limitedTo mods: UInt16) -> UInt64 {
        var f: UInt64 = 0
        for (code, n) in counts where n > 0 {
            if let m = Modifiers.key(code), mods & m.wire != 0 { f |= m.mask }
        }
        return f
    }

    /// Which modifiers `pressTemp(mods)` would press now, in order.
    func missingTemps(_ mods: UInt16) -> [UInt16] {
        var held = self
        var out: [UInt16] = []
        for m in Modifiers.tempOrder where mods & m.wire != 0 {
            let skip = m.isRight ? held.isDown(m.code) : (held.modifierFlags & m.generic != 0)
            if skip { continue }
            _ = held.press(m.code)
            out.append(m.code)
        }
        return out
    }

    mutating func removeAll() { counts = [:] }
}

/// Generic press counts for mouse buttons (SPEC §10.5).
struct ButtonRefcount {
    private(set) var counts: [MouseButton: Int] = [:]

    func isDown(_ b: MouseButton) -> Bool { (counts[b] ?? 0) > 0 }

    mutating func press(_ b: MouseButton) -> Bool {
        let n = (counts[b] ?? 0) + 1
        counts[b] = n
        return n == 1
    }

    mutating func release(_ b: MouseButton) -> Bool {
        guard let n = counts[b], n > 0 else { return false }
        counts[b] = n == 1 ? nil : n - 1
        return n == 1
    }

    /// The first held button in the order Left, Right, Middle, Back, Forward.
    var dragging: MouseButton? { MouseButton.allCases.first { isDown($0) } }
}

extension MediaKey {
    /// NX_KEYTYPE_* (SPEC §10.9).
    var nxKeyType: Int32 {
        switch self {
        case .volumeUp: 0
        case .volumeDown: 1
        case .brightnessUp: 2
        case .brightnessDown: 3
        case .mute: 7
        case .playPause: 16
        case .next: 17
        case .previous: 18
        case .fastForward: 19
        case .rewind: 20
        case .illuminationUp: 21
        case .illuminationDown: 22
        case .illuminationToggle: 23
        }
    }

    /// `data1` of the system-defined event.
    func data1(down: Bool) -> Int {
        (Int(nxKeyType) << 16) | (down ? 0x0A00 : 0x0B00)
    }
}
