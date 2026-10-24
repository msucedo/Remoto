import Carbon
import Foundation
import RemotoCore

/// Reads the active keyboard layout with Text Input Sources and
/// `UCKeyTranslate` (SPEC §15.7). TIS must be used on the main thread.
@MainActor
enum KeyboardLayoutReader {
    /// The 51 key codes the phone needs: 0x00–0x23, 0x25–0x2F, 0x32, 0x5D–0x5F.
    static let keyCodes: [UInt16] = Array(0x00...0x23) + Array(0x25...0x2F) + [0x32, 0x5D, 0x5E, 0x5F]

    private static let spaceKey: UInt16 = 0x31
    private static let shift = UInt32(shiftKey >> 8) & 0xFF
    private static let option = UInt32(optionKey >> 8) & 0xFF

    static func current() -> KeyboardLayout? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let layoutData: CFData = property(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let id: CFString = property(source, kTISPropertyInputSourceID) ?? "" as CFString
        let name: CFString = property(source, kTISPropertyLocalizedName) ?? id
        let keyboardType = UInt32(LMGetKbdType())
        let iso = KBGetLayoutType(Int16(keyboardType)) == UInt32(kKeyboardISO)

        let bytes = CFDataGetBytePtr(layoutData)!
        let keys = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            keyCodes.map { code -> KeyCap in
                let base = translate(layout, code, 0, keyboardType)
                let shifted = translate(layout, code, shift, keyboardType)
                let opt = translate(layout, code, option, keyboardType)
                let optShift = translate(layout, code, option | shift, keyboardType)
                var dead: UInt8 = 0
                for (bit, result) in [base, shifted, opt, optShift].enumerated() where result.dead {
                    dead |= 1 << UInt8(bit)
                }
                return KeyCap(
                    code: code, base: base.text, shift: shifted.text, option: opt.text, optionShift: optShift.text,
                    dead: dead)
            }
        }
        return KeyboardLayout(id: id as String, name: name as String, iso: iso, keys: keys)
    }

    private static func property<T>(_ source: TISInputSource, _ key: CFString) -> T? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue() as? T
    }

    /// The text a key produces with `modifiers`. For a dead key, the accent on
    /// its own (what pressing Space next would give) and `dead == true`.
    private static func translate(
        _ layout: UnsafePointer<UCKeyboardLayout>, _ code: UInt16, _ modifiers: UInt32, _ keyboardType: UInt32
    ) -> (text: String, dead: Bool) {
        var deadState: UInt32 = 0
        var text = run(layout, code, modifiers, keyboardType, &deadState)
        let dead = deadState != 0
        if dead {
            text = run(layout, spaceKey, 0, keyboardType, &deadState)
        }
        if text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { text = "" }
        return (text, dead)
    }

    private static func run(
        _ layout: UnsafePointer<UCKeyboardLayout>, _ code: UInt16, _ modifiers: UInt32, _ keyboardType: UInt32,
        _ deadState: inout UInt32
    ) -> String {
        var chars = [UniChar](repeating: 0, count: 8)
        var length = 0
        let status = UCKeyTranslate(
            layout, code, UInt16(kUCKeyActionDown), modifiers, keyboardType, OptionBits(0), &deadState, chars.count,
            &length, &chars)
        guard status == noErr else { return "" }
        return String(utf16CodeUnits: chars, count: length)
    }
}
