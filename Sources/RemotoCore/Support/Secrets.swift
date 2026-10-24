import Crypto
import Foundation

/// Random tokens, hashing and constant-time comparison (SPEC §6.1, §7.1).
enum Secrets {
    /// `count` bytes from the system CSPRNG.
    static func randomBytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }

    /// `count` random bytes as base64url without padding.
    static func randomToken(_ count: Int) -> String {
        base64URL(randomBytes(count))
    }

    static func base64URL(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func sha256(_ text: String) -> [UInt8] {
        Array(SHA256.hash(data: Data(text.utf8)))
    }

    /// Lowercase hex of SHA-256 of the UTF-8 text.
    static func sha256Hex(_ text: String) -> String {
        hex(sha256(text))
    }

    static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Compares two byte strings without an early exit on the first difference.
    /// The length is not secret (tokens and digests have fixed sizes).
    static func constantTimeEquals(_ a: some Collection<UInt8>, _ b: some Collection<UInt8>) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }

    /// Constant-time comparison of two strings by their SHA-256 digests, so even
    /// different lengths take the same path.
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        constantTimeEquals(sha256(a), sha256(b))
    }
}
