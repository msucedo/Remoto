/// The QR code and PIN, which share one 600 s life (SPEC §6.1).
struct PairingSecret: Sendable, Equatable {
    static let lifetime: Double = 600

    var code: String
    var pin: String
    var createdAt: Double

    static func fresh(now: Double) -> PairingSecret {
        PairingSecret(code: Secrets.randomToken(18), pin: makePin(), createdAt: now)
    }

    func age(now: Double) -> Double { max(0, now - createdAt) }
    func isExpired(now: Double) -> Bool { age(now: now) >= Self.lifetime }

    func expiresIn(now: Double) -> UInt32 {
        let left = Self.lifetime - age(now: now)
        return left <= 0 ? 0 : UInt32(left.rounded(.down))
    }

    /// Six uniform digits, re-drawn when they are all equal or a straight run.
    static func makePin() -> String {
        var generator = SystemRandomNumberGenerator()
        while true {
            let n = UInt32.random(in: 0..<1_000_000, using: &generator)
            let pin = String(n).leftPadded(to: 6)
            if !isGuessable(pin) { return pin }
        }
    }

    static func isGuessable(_ pin: String) -> Bool {
        let d = pin.utf8.map { Int($0) - 0x30 }
        guard d.count > 1 else { return true }
        let steps = zip(d.dropFirst(), d).map { $0 - $1 }
        return steps.allSatisfy { $0 == 0 } || steps.allSatisfy { $0 == 1 } || steps.allSatisfy { $0 == -1 }
    }
}

extension String {
    func leftPadded(to width: Int, with pad: Character = "0") -> String {
        count >= width ? self : String(repeating: pad, count: width - count) + self
    }
}
