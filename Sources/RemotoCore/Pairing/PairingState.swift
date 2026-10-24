/// Result of one authentication attempt.
enum AuthOutcome: Equatable, Sendable {
    case ok
    case denied(DenyReason, retryAfter: UInt32? = nil)
}

/// Code, PIN, PIN window and limiters (SPEC §6.1–§6.3). Pure value type; the
/// caller passes the monotonic time.
struct PairingState: Sendable {
    static let pinGrace: Double = 180

    private(set) var secret: PairingSecret
    private(set) var pinVisible = false
    private(set) var openUntil: Double = -.infinity
    private(set) var pinFailures = RateLimiter(threshold: 5)
    private(set) var approvalFailures = RateLimiter(threshold: 3)
    private(set) var global = GlobalFailureWindow()

    init(now: Double) { secret = .fresh(now: now) }

    mutating func rotate(now: Double) { secret = .fresh(now: now) }

    @discardableResult
    mutating func rotateIfExpired(now: Double) -> Bool {
        guard secret.isExpired(now: now) else { return false }
        rotate(now: now)
        return true
    }

    /// Single-use QR code check. Failures are not counted.
    mutating func checkCode(_ code: String, now: Double) -> AuthOutcome {
        if rotateIfExpired(now: now) { return .denied(.expiredCode) }
        guard Secrets.constantTimeEquals(code, secret.code) else { return .denied(.expiredCode) }
        rotate(now: now)
        return .ok
    }

    mutating func setPinVisible(_ visible: Bool, now: Double) {
        if pinVisible && !visible { openUntil = now + Self.pinGrace }
        pinVisible = visible
    }

    func isPinOpen(now: Double) -> Bool { pinVisible || now < openUntil }

    mutating func checkPin(_ input: String, ip: String, now: Double) -> AuthOutcome {
        let digits = String(input.unicodeScalars.filter { $0.value >= 0x30 && $0.value <= 0x39 }.map(Character.init))
        guard isPinOpen(now: now) else { return .denied(.pinClosed) }
        pinFailures.pruneIfNeeded(now: now)
        let key = RateLimiter.key(for: ip)
        let remaining = [pinFailures.lockRemaining(key, now: now), global.lockRemaining(now: now)].compactMap { $0 }
        if let wait = remaining.max() {
            return .denied(.blocked, retryAfter: RateLimiter.retrySeconds(wait))
        }
        if secret.isExpired(now: now) {
            rotate(now: now)
            countPinFailure(key: key, now: now)
            return .denied(.wrongPin)
        }
        if Secrets.constantTimeEquals(digits, secret.pin) {
            rotate(now: now)
            return .ok
        }
        countPinFailure(key: key, now: now)
        return .denied(.wrongPin)
    }

    private mutating func countPinFailure(key: String, now: Double) {
        global.add(now: now)
        if pinFailures.add(key, now: now) {
            // A lockout started: the PIN that was being guessed is retired.
            secret.pin = PairingSecret.makePin()
        }
    }

    func approvalLockRemaining(ip: String, now: Double) -> Double? {
        approvalFailures.lockRemaining(RateLimiter.key(for: ip), now: now)
    }

    mutating func countApprovalFailure(ip: String, now: Double) {
        approvalFailures.pruneIfNeeded(now: now)
        approvalFailures.add(RateLimiter.key(for: ip), now: now)
    }
}
