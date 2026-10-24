import Foundation
import NIOHTTP1

/// A response before it is written (SPEC §4.9).
struct HTTPReply: Sendable {
    var status: Int
    var contentType: String
    var body: [UInt8]
    var extraHeaders: [(String, String)] = []
    /// Overrides `Content-Length` (used by 304, which has no body).
    var contentLength: Int?
    /// Close after writing, whatever keep-alive says.
    var forceClose = false

    static func text(_ status: Int, _ message: String, extra: [(String, String)] = [], close: Bool = false) -> HTTPReply {
        HTTPReply(
            status: status, contentType: "text/plain; charset=utf-8", body: Array(message.utf8), extraHeaders: extra,
            forceClose: close)
    }
}

/// Who is asking, after proxy rules (SPEC §4.4).
struct ClientIdentity: Equatable, Sendable {
    var ip: String
    var secure: Bool
    var host: String?
}

enum HTTPRules {
    static let maxHeaderBytes = 16_384
    static let firstHeaderTimeout: Double = 30
    static let nextHeaderTimeout: Double = 10
    static let maxRequestsPerSocket = 200
    static let maxSocketAge: Double = 120
    static let keepAliveConnectionLimit = 96

    static let csp =
        "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; connect-src 'self' ws: wss:; worker-src 'self'; manifest-src 'self'; media-src 'self' blob:; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 304: "Not Modified"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 421: "Misdirected Request"
        case 426: "Upgrade Required"
        default: "Error"
        }
    }

    /// Headers in the normative order: type, length, connection, security, extras.
    static func headers(for reply: HTTPReply, keepAlive: Bool) -> HTTPHeaders {
        var h = HTTPHeaders()
        h.add(name: "Content-Type", value: reply.contentType)
        h.add(name: "Content-Length", value: String(reply.contentLength ?? reply.body.count))
        h.add(name: "Connection", value: keepAlive ? "keep-alive" : "close")
        h.add(name: "X-Content-Type-Options", value: "nosniff")
        h.add(name: "Referrer-Policy", value: "no-referrer")
        h.add(name: "X-Frame-Options", value: "DENY")
        h.add(name: "Content-Security-Policy", value: csp)
        for (name, value) in reply.extraHeaders { h.add(name: name, value: value) }
        return h
    }

    /// Whether a comma-separated header contains `token` (case-insensitive).
    static func hasToken(_ headers: HTTPHeaders, _ name: String, _ token: String) -> Bool {
        headers[name].contains { value in
            value.split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == token }
        }
    }

    /// First or last comma-separated value of a header across all its lines.
    static func listValue(_ headers: HTTPHeaders, _ name: String, last: Bool) -> String? {
        let values = headers[name].flatMap { $0.split(separator: ",", omittingEmptySubsequences: false) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return (last ? values.last : values.first).flatMap { $0.isEmpty ? nil : $0 }
    }

    static func isLoopback(_ ip: String) -> Bool {
        ip.hasPrefix("127.") || ip == "::1" || ip.lowercased().hasPrefix("::ffff:127.")
    }

    /// IPv4-mapped IPv6 becomes plain IPv4.
    static func normalizeIP(_ ip: String) -> String {
        let lower = ip.lowercased()
        if lower.hasPrefix("::ffff:"), HostRules.isIPv4(String(lower.dropFirst(7))) { return String(lower.dropFirst(7)) }
        return ip
    }

    /// Strips a `:port` from an `X-Forwarded-For` value.
    static func forwardedIP(_ raw: String) -> String? {
        var s = raw
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            s = String(s[s.index(after: s.startIndex)..<close])
        } else if !HostRules.isIPv6(s), let colon = s.lastIndex(of: ":") {
            s = String(s[..<colon])
        }
        guard HostRules.isIPv4(s) || HostRules.isIPv6(s) else { return nil }
        return normalizeIP(s)
    }

    static func identity(peerIP: String, tls: Bool, headers: HTTPHeaders, allowLocalProxy: Bool) -> ClientIdentity {
        let peer = normalizeIP(peerIP)
        var identity = ClientIdentity(ip: peer, secure: tls, host: headers.first(name: "Host"))
        guard allowLocalProxy, isLoopback(peer) else { return identity }
        if let forwarded = listValue(headers, "X-Forwarded-For", last: true), let ip = forwardedIP(forwarded) {
            identity.ip = ip
        }
        if let proto = listValue(headers, "X-Forwarded-Proto", last: false), proto.lowercased() == "https" {
            identity.secure = true
        }
        if let host = listValue(headers, "X-Forwarded-Host", last: false) {
            identity.host = host
        }
        return identity
    }

    /// `Transfer-Encoding`, or any `Content-Length` other than 0.
    static func hasBody(_ headers: HTTPHeaders) -> Bool {
        if headers.contains(name: "Transfer-Encoding") { return true }
        return headers["Content-Length"].contains { $0.trimmingCharacters(in: .whitespaces) != "0" }
    }

    /// The first checks every request goes through (SPEC §4.5); nil means go on.
    static func precheck(_ head: HTTPRequestHead, identity: ClientIdentity, customHost: String?) -> HTTPReply? {
        guard head.method == .GET else { return .text(405, "Only GET is supported.", close: true) }
        if hasBody(head.headers) { return .text(400, "Requests can't have a body.", close: true) }
        guard let host = identity.host, HostRules.isAccepted(host, customHost: customHost) else {
            return .text(421, "This address isn't served here.", close: true)
        }
        return nil
    }

    /// WebSocket handshake checks (SPEC §4.8); nil means upgrade.
    static func websocketCheck(_ head: HTTPRequestHead, identity: ClientIdentity) -> HTTPReply? {
        guard hasToken(head.headers, "Upgrade", "websocket"), hasToken(head.headers, "Connection", "upgrade") else {
            return .text(426, "This endpoint needs a WebSocket upgrade.", extra: [("Upgrade", "websocket")], close: true)
        }
        guard head.headers.first(name: "Sec-WebSocket-Version")?.trimmingCharacters(in: .whitespaces) == "13" else {
            return .text(400, "Unsupported WebSocket version.", extra: [("Sec-WebSocket-Version", "13")], close: true)
        }
        guard let key = head.headers.first(name: "Sec-WebSocket-Key"), !key.isEmpty else {
            return .text(400, "Missing Sec-WebSocket-Key.", close: true)
        }
        if let origin = head.headers.first(name: "Origin") {
            let rest = origin.range(of: "://").map { String(origin[$0.upperBound...]) } ?? origin
            guard let host = identity.host, rest.lowercased() == host.lowercased() else {
                return .text(403, "Cross-origin WebSocket refused.", close: true)
            }
        }
        return nil
    }

    static func keepAlive(
        version: HTTPVersion, headers: HTTPHeaders, served: Int, socketAge: Double, openConnections: Int
    ) -> Bool {
        let wants: Bool
        if version.major == 1 && version.minor == 0 {
            wants = hasToken(headers, "Connection", "keep-alive")
        } else if version.major == 1 && version.minor >= 1 {
            wants = !hasToken(headers, "Connection", "close")
        } else {
            wants = false
        }
        return wants && served < maxRequestsPerSocket && socketAge < maxSocketAge
            && openConnections < keepAliveConnectionLimit
    }

    // MARK: Paths and queries

    /// Splits a request target into path and query, without decoding.
    static func splitTarget(_ uri: String) -> (path: String, query: String) {
        var target = Substring(uri)
        if let hash = target.firstIndex(of: "#") { target = target[..<hash] }
        guard let q = target.firstIndex(of: "?") else { return (String(target), "") }
        return (String(target[..<q]), String(target[target.index(after: q)...]))
    }

    static func percentDecode(_ s: Substring) -> String? {
        var bytes: [UInt8] = []
        var it = s.utf8.makeIterator()
        while let b = it.next() {
            if b == UInt8(ascii: "%") {
                guard let h = it.next(), let l = it.next(), let hv = hexValue(h), let lv = hexValue(l) else { return nil }
                bytes.append(hv << 4 | lv)
            } else {
                bytes.append(b)
            }
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    private static func hexValue(_ b: UInt8) -> UInt8? {
        switch b {
        case 0x30...0x39: b - 0x30
        case 0x41...0x46: b - 0x41 + 10
        case 0x61...0x66: b - 0x61 + 10
        default: nil
        }
    }

    static func queryItems(_ query: String) -> [String: String] {
        var items: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = percentDecode(parts[0]) else { continue }
            let value = parts.count > 1 ? percentDecode(parts[1]) ?? "" : ""
            if items[key] == nil { items[key] = value }
        }
        return items
    }

    /// `/api/icon` size bucket (SPEC §4.7).
    static func iconBucket(_ raw: String?) -> Int {
        var size = 128
        if let raw, !raw.isEmpty, raw.count <= 8, raw.allSatisfy(\.isASCIIDigit), let n = Int(raw) { size = n }
        switch size {
        case ...64: return 64
        case ...128: return 128
        case ...256: return 256
        default: return 512
        }
    }

    static func contentType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "js", "mjs": "text/javascript; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "html": "text/html; charset=utf-8"
        case "json": "application/json"
        case "webmanifest": "application/manifest+json"
        case "svg": "image/svg+xml"
        case "wasm": "application/wasm"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "ico": "image/x-icon"
        case "webp": "image/webp"
        case "woff2": "font/woff2"
        case "txt": "text/plain; charset=utf-8"
        default: "application/octet-stream"
        }
    }

    static func etag(length: Int, mtimeNanos: UInt64) -> String {
        "\"\(String(length, radix: 16))-\(String(mtimeNanos, radix: 16))\""
    }
}
