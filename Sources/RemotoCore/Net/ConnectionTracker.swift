import NIOCore

/// Open-connection accounting and limits (SPEC §4.2).
final class ConnectionTracker: Sendable {
    static let maxTotal = 128
    static let maxPerIP = 16
    static let maxPerLoopbackProxy = 64

    private struct State {
        var nextID: UInt64 = 1
        var byID: [UInt64: (ip: String, channel: Channel?)] = [:]
        var perIP: [String: Int] = [:]
    }

    private let state = Locked(State())

    /// Registers a connection, or returns nil when a limit would be passed.
    func admit(ip rawIP: String, channel: Channel?, allowLocalProxy: Bool) -> UInt64? {
        let address = HTTPRules.normalizeIP(rawIP)
        // Same grouping as the pairing limiter: IPv4 as is, IPv6 by /64.
        let ip = RateLimiter.key(for: address)
        let perIPLimit = allowLocalProxy && HTTPRules.isLoopback(address) ? Self.maxPerLoopbackProxy : Self.maxPerIP
        return state.withLock { s in
            guard s.byID.count < Self.maxTotal, s.perIP[ip, default: 0] < perIPLimit else { return nil }
            let id = s.nextID
            s.nextID += 1
            s.byID[id] = (ip, channel)
            s.perIP[ip, default: 0] += 1
            return id
        }
    }

    func release(_ id: UInt64) {
        state.withLock { s in
            guard let entry = s.byID.removeValue(forKey: id) else { return }
            let left = s.perIP[entry.ip, default: 1] - 1
            s.perIP[entry.ip] = left > 0 ? left : nil
        }
    }

    var openCount: Int { state.withLock { $0.byID.count } }

    var channels: [Channel] { state.withLock { $0.byID.values.compactMap(\.channel) } }
}
