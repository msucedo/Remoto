import Darwin
import Foundation

/// A local IPv4 address and how it is ranked (SPEC §3.1).
struct LocalAddress: Sendable, Equatable {
    var ip: String
    var interface: String
    var priority: Int
    var vpn: Bool
}

enum Addresses {
    static let vpnPrefixes = ["utun", "ipsec", "ppp", "tun", "tap", "wg", "tz", "feth"]
    static let auxPrefixes = ["awdl", "llw", "bridge"]

    static func classify(interface name: String) -> (priority: Int, vpn: Bool) {
        if name.hasPrefix("en") { return (0, false) }
        if vpnPrefixes.contains(where: name.hasPrefix) { return (2, true) }
        if auxPrefixes.contains(where: name.hasPrefix) { return (2, false) }
        return (1, false)
    }

    static func ipv4Bytes(_ ip: String) -> [UInt8]? {
        var addr = in_addr()
        guard inet_pton(AF_INET, ip, &addr) == 1 else { return nil }
        return withUnsafeBytes(of: addr.s_addr) { Array($0) }
    }

    static func ipv4Number(_ ip: String) -> UInt32? {
        guard let b = ipv4Bytes(ip) else { return nil }
        return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }

    static func isExcluded(_ ip: String) -> Bool {
        guard let b = ipv4Bytes(ip) else { return true }
        if b == [0, 0, 0, 0] { return true }
        if b[0] == 127 { return true }
        if b[0] == 169 && b[1] == 254 { return true }
        return false
    }

    /// Filters, ranks by (priority, IP, vpn) and removes duplicate IPs.
    static func rank(_ raw: [(interface: String, ip: String)]) -> [LocalAddress] {
        var list = raw.compactMap { item -> LocalAddress? in
            guard !isExcluded(item.ip) else { return nil }
            let c = classify(interface: item.interface)
            return LocalAddress(ip: item.ip, interface: item.interface, priority: c.priority, vpn: c.vpn)
        }
        list.sort { a, b in
            if a.priority != b.priority { return a.priority < b.priority }
            let na = ipv4Number(a.ip) ?? 0
            let nb = ipv4Number(b.ip) ?? 0
            if na != nb { return na < nb }
            return !a.vpn && b.vpn
        }
        var seen = Set<String>()
        return list.filter { seen.insert($0.ip).inserted }
    }

    /// The IPv4 addresses of interfaces that are up, ranked.
    static func current() -> [LocalAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var raw: [(interface: String, ip: String)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let sa = entry.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            guard entry.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let rc = getnameinfo(
                sa, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            guard rc == 0 else { continue }
            let ip = String(decoding: host.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            raw.append((String(cString: entry.pointee.ifa_name), ip))
        }
        return rank(raw)
    }
}
