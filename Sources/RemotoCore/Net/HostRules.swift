import Darwin

/// `Host` header acceptance (anti DNS-rebinding, SPEC §4.6) and the pairing
/// link host (SPEC §3.2).
enum HostRules {
    static func isIPv4(_ s: String) -> Bool {
        var a = in_addr()
        return inet_pton(AF_INET, s, &a) == 1
    }

    static func isIPv6(_ s: String) -> Bool {
        var a = in6_addr()
        return inet_pton(AF_INET6, s, &a) == 1
    }

    static func isPort(_ s: Substring) -> Bool {
        !s.isEmpty && s.count <= 5 && s.allSatisfy(\.isASCIIDigit) && UInt16(s) != nil
    }

    /// Strips a valid `:port`, trailing dots, and lowercases.
    static func normalize(_ raw: String) -> String {
        var host = Substring(raw.trimmingCharacters(in: .whitespaces))
        if host.hasPrefix("[") {
            if let close = host.firstIndex(of: "]") {
                let rest = host[host.index(after: close)...]
                if rest.hasPrefix(":"), isPort(rest.dropFirst()) {
                    host = host[...close]
                }
            }
        } else if !isIPv6(String(host)), let colon = host.lastIndex(of: ":") {
            if isPort(host[host.index(after: colon)...]) {
                host = host[..<colon]
            }
        }
        while host.hasSuffix(".") { host = host.dropLast() }
        return host.lowercased()
    }

    static func isLabel(_ s: Substring) -> Bool {
        !s.isEmpty && s.utf8.allSatisfy { b in
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x2D
        }
    }

    /// Whether a request's `Host` names this Mac in a way a rebinding attack can't fake.
    static func isAccepted(_ raw: String, customHost: String?) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if isIPv6(trimmed) { return true }
        let host = normalize(trimmed)
        guard !host.isEmpty else { return false }
        if host.hasPrefix("[") && host.hasSuffix("]") {
            return isIPv6(String(host.dropFirst().dropLast()))
        }
        if isIPv4(host) { return true }
        if let customHost, !customHost.isEmpty, host == customHost { return true }
        if host == "localhost" { return true }
        if !host.contains(".") {
            return isLabel(Substring(host)) && host != "local" && host != "internal"
        }
        for suffix in [".local", ".home.arpa", ".internal"] where host.hasSuffix(suffix) {
            let rest = host.dropLast(suffix.count)
            return !rest.isEmpty && rest.split(separator: ".", omittingEmptySubsequences: false).allSatisfy(isLabel)
        }
        return false
    }

    /// A custom link address split into host and optional port, or nil if it
    /// can't be understood. The host keeps brackets for IPv6.
    static func parseCustom(_ raw: String) -> (host: String, port: UInt16?)? {
        var s = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        for scheme in ["http://", "https://"] where s.lowercased().hasPrefix(scheme) {
            s = s.dropFirst(scheme.count)
            break
        }
        while s.hasSuffix("/") { s = s.dropLast() }
        guard !s.isEmpty, !s.contains(where: { $0.isWhitespace || "/?#@\\".contains($0) }) else { return nil }
        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]") else { return nil }
            let inner = s[s.index(after: s.startIndex)..<close]
            guard isIPv6(String(inner)) else { return nil }
            let rest = s[s.index(after: close)...]
            if rest.isEmpty { return ("[\(inner)]", nil) }
            guard rest.hasPrefix(":"), isPort(rest.dropFirst()), let port = UInt16(rest.dropFirst()) else {
                return nil
            }
            return ("[\(inner)]", port)
        }
        if isIPv6(String(s)) { return ("[\(s)]", nil) }
        if let colon = s.firstIndex(of: ":") {
            let host = s[..<colon]
            let port = s[s.index(after: colon)...]
            guard !host.isEmpty, isPort(port), let p = UInt16(port) else { return nil }
            return (String(host), p)
        }
        return (String(s), nil)
    }

    /// The `host:port` that goes in the pairing link.
    static func linkAuthority(linkHost: LinkHost, hostName: String, ip: String, port: UInt16) -> String {
        switch linkHost {
        case .ipAddress:
            return "\(ip):\(port)"
        case .custom(let raw):
            if let parsed = parseCustom(raw) {
                return "\(parsed.host):\(parsed.port ?? port)"
            }
            return linkAuthority(linkHost: .hostName, hostName: hostName, ip: ip, port: port)
        case .hostName:
            var name = Substring(hostName.trimmingCharacters(in: .whitespaces))
            while name.hasSuffix(".") { name = name.dropLast() }
            return "\(name.isEmpty ? ip : String(name)):\(port)"
        }
    }

    /// The normalized custom host that `Host` checks also accept.
    static func acceptedCustomHost(_ linkHost: LinkHost) -> String? {
        guard case .custom(let raw) = linkHost, let parsed = parseCustom(raw) else { return nil }
        return normalize(parsed.host)
    }
}

extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

import Foundation
