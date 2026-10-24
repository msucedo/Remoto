/// Name sanitizing for device names and models (SPEC §7.4).
enum TextClean {
    /// Marks a name set on the Mac; the phone can't overwrite it.
    static let renamedMark: Unicode.Scalar = "\u{200B}"
    static let unnamed = "Unnamed device"

    static func isInvisible(_ v: UInt32) -> Bool {
        switch v {
        case 0x00..<0x20, 0x7F...0x9F, 0xAD, 0x61C, 0x180E, 0x200B...0x200F, 0x202A...0x202E,
            0x2064...0x206F, 0xFEFF:
            return true
        default:
            return false
        }
    }

    /// Drops control and invisible format characters, keeps at most `max`
    /// characters, then trims surrounding whitespace.
    static func clean(_ text: String, max: Int) -> String {
        var out = String.UnicodeScalarView()
        var kept = 0
        for scalar in text.unicodeScalars where !isInvisible(scalar.value) {
            guard kept < max else { break }
            out.append(scalar)
            kept += 1
        }
        return String(out).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func displayName(_ text: String) -> String {
        let name = clean(text, max: 64)
        return name.isEmpty ? unnamed : name
    }

    /// The stored name without the "renamed on the Mac" mark.
    static func presented(_ stored: String) -> String {
        var scalars = Substring(stored).unicodeScalars
        if scalars.first == renamedMark { scalars.removeFirst() }
        return String(String.UnicodeScalarView(scalars))
    }
}

import Foundation
