import Darwin

/// Per-key failure counting with escalating lockouts (SPEC §6.3).
struct RateLimiter: Sendable {
    struct Entry: Sendable, Equatable {
        var lockedUntil: Double?
        var last: Double
        var count: Int
        var lockouts: Int
    }

    static let resetAfter: Double = 3600
    static let maxKeys = 1024

    let threshold: Int
    private(set) var entries: [String: Entry] = [:]

    init(threshold: Int) { self.threshold = threshold }

    static func lockDuration(lockouts: Int) -> Double {
        lockouts < 5 ? Double(30 << lockouts) : 900
    }

    /// Seconds left on an active lockout, or nil.
    func lockRemaining(_ key: String, now: Double) -> Double? {
        guard let until = entries[key]?.lockedUntil, until > now else { return nil }
        return until - now
    }

    /// Counts one failure. Returns true when this failure started a lockout.
    @discardableResult
    mutating func add(_ key: String, now: Double) -> Bool {
        var e = entries[key] ?? Entry(lockedUntil: nil, last: now, count: 0, lockouts: 0)
        let locked = (e.lockedUntil ?? 0) > now
        if now - e.last >= Self.resetAfter && !locked {
            e.count = 0
            e.lockouts = 0
        }
        e.last = now
        e.count += 1
        var started = false
        if e.count >= threshold {
            e.lockedUntil = now + Self.lockDuration(lockouts: e.lockouts)
            e.count = 0
            e.lockouts += 1
            started = true
        }
        entries[key] = e
        return started
    }

    /// Drops idle entries once the map grows past 1024 keys; if that isn't
    /// enough, drops the oldest unlocked ones.
    mutating func pruneIfNeeded(now: Double) {
        guard entries.count > Self.maxKeys else { return }
        entries = entries.filter { _, e in
            (e.lockedUntil ?? 0) > now || now - e.last < Self.resetAfter
        }
        guard entries.count > Self.maxKeys else { return }
        let removable = entries.filter { ($0.value.lockedUntil ?? 0) <= now }
            .sorted { $0.value.last < $1.value.last }
        for (key, _) in removable.prefix(entries.count - Self.maxKeys) {
            entries.removeValue(forKey: key)
        }
    }

    /// The limiting key for an address: the IPv4 itself (also when mapped in
    /// IPv6), or the /64 prefix of an IPv6 address.
    static func key(for ip: String) -> String {
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, ip, &v6) == 1 else { return ip }
        let bytes = withUnsafeBytes(of: v6) { Array($0) }
        if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xFF && bytes[11] == 0xFF {
            return bytes[12..<16].map(String.init).joined(separator: ".")
        }
        let groups = stride(from: 0, to: 8, by: 2).map { String(UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]), radix: 16) }
        return groups.joined(separator: ":") + "::/64"
    }

    /// `retryAfter` in whole seconds: rounded up, never below 1.
    static func retrySeconds(_ remaining: Double) -> UInt32 {
        max(1, UInt32(min(remaining.rounded(.up), Double(UInt32.max))))
    }
}

/// All PIN failures across keys in the last 60 s (SPEC §6.3, global row).
struct GlobalFailureWindow: Sendable {
    static let window: Double = 60
    static let limit = 20
    private(set) var failures: [Double] = []

    mutating func add(now: Double) {
        trim(now: now)
        failures.append(now)
    }

    mutating func trim(now: Double) {
        failures.removeAll { now - $0 >= Self.window }
    }

    /// Seconds until the window drops under the limit, or nil when not blocked.
    mutating func lockRemaining(now: Double) -> Double? {
        trim(now: now)
        guard failures.count >= Self.limit, let oldest = failures.first else { return nil }
        return Self.window - (now - oldest)
    }
}
