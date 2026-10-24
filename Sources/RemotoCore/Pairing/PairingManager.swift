/// Owns the pairing state and the pending Mac approvals (SPEC §6).
actor PairingManager {
    static let maxPendingApprovals = 2
    static let approvalTimeout: Double = 120

    private var state: PairingState
    private var pending: [UInt64: Pending] = [:]
    private let now: @Sendable () -> Double

    private struct Pending {
        var key: String
        var decision: Bool?
        var waiter: CheckedContinuation<Bool?, Never>?
    }

    enum ApprovalStart: Equatable, Sendable {
        case started
        case denied(AuthOutcome)
    }

    init(now: @escaping @Sendable () -> Double = Mono.now) {
        self.now = now
        state = PairingState(now: now())
    }

    var secret: PairingSecret { state.secret }

    /// Returns whether the code/PIN changed.
    func rotateIfExpired() -> Bool { state.rotateIfExpired(now: now()) }

    func renew() { state.rotate(now: now()) }

    func setPinVisible(_ visible: Bool) { state.setPinVisible(visible, now: now()) }

    /// Returns the outcome and whether the code/PIN changed as a result.
    func checkCode(_ code: String) -> (AuthOutcome, changed: Bool) {
        let before = state.secret
        let outcome = state.checkCode(code, now: now())
        return (outcome, state.secret != before)
    }

    func checkPin(_ pin: String, ip: String) -> (AuthOutcome, changed: Bool) {
        let before = state.secret
        let outcome = state.checkPin(pin, ip: ip, now: now())
        return (outcome, state.secret != before)
    }

    // MARK: Approvals (SPEC §6.4)

    func beginApproval(id: UInt64, ip: String) -> ApprovalStart {
        let t = now()
        if let wait = state.approvalLockRemaining(ip: ip, now: t) {
            return .denied(.denied(.blocked, retryAfter: RateLimiter.retrySeconds(wait)))
        }
        let key = RateLimiter.key(for: ip)
        if pending.count >= Self.maxPendingApprovals || pending.values.contains(where: { $0.key == key }) {
            return .denied(.denied(.busy))
        }
        pending[id] = Pending(key: key)
        return .started
    }

    /// Waits for `respond`; nil when the request ended some other way.
    func waitForDecision(id: UInt64) async -> Bool? {
        guard let entry = pending[id] else { return nil }
        if let decision = entry.decision { return decision }
        return await withCheckedContinuation { continuation in
            pending[id]?.waiter = continuation
        }
    }

    /// Returns false when there is no such pending request.
    func respond(id: UInt64, allow: Bool) -> Bool {
        guard var entry = pending[id], entry.decision == nil else { return false }
        entry.decision = allow
        if let waiter = entry.waiter {
            entry.waiter = nil
            waiter.resume(returning: allow)
        }
        pending[id] = entry
        return true
    }

    /// Removes the request; counts a failure unless it was approved.
    func endApproval(id: UInt64, ip: String, approved: Bool) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.waiter?.resume(returning: nil)
        if !approved { state.countApprovalFailure(ip: ip, now: now()) }
    }

    var pendingIDs: [UInt64] { Array(pending.keys) }
}
