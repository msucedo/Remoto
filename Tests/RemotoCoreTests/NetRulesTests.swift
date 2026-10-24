import Foundation
import NIOHTTP1
import Testing
@testable import RemotoCore

@Suite struct AddressTests {
    @Test func classification() {
        #expect(Addresses.classify(interface: "en0") == (0, false))
        #expect(Addresses.classify(interface: "utun3") == (2, true))
        #expect(Addresses.classify(interface: "wg0") == (2, true))
        #expect(Addresses.classify(interface: "awdl0") == (2, false))
        #expect(Addresses.classify(interface: "bridge100") == (2, false))
        #expect(Addresses.classify(interface: "vmnet8") == (1, false))
    }

    @Test func rankingFilteringAndDedup() {
        let ranked = Addresses.rank([
            ("utun4", "100.64.1.2"), ("en0", "192.168.1.20"), ("lo0", "127.0.0.1"), ("en7", "169.254.3.3"),
            ("vmnet1", "172.16.5.1"), ("en1", "10.0.0.5"), ("en5", "192.168.1.20"), ("en9", "0.0.0.0"),
        ])
        #expect(ranked.map(\.ip) == ["10.0.0.5", "192.168.1.20", "172.16.5.1", "100.64.1.2"])
        #expect(ranked.filter(\.vpn).map(\.ip) == ["100.64.1.2"])
    }

    @Test func currentAddressesAreIPv4() {
        for address in Addresses.current() {
            #expect(HostRules.isIPv4(address.ip))
            #expect(!address.ip.hasPrefix("127."))
        }
    }
}

@Suite struct HostRulesTests {
    @Test func accepted() {
        for host in [
            "mac.local:8740", "192.168.1.5", "[::1]:8740", "[::1]", "router.home.arpa", "mymac", "localhost",
            "localhost:7979", "Mac.Local.", "box.internal", "10.0.0.1:80", "::1",
        ] {
            #expect(HostRules.isAccepted(host, customHost: nil), "\(host)")
        }
    }

    @Test func rejected() {
        for host in ["evil.example.com", "local", "home.arpa", "internal", "", "a b", "mac.local:99999", ".local", "x..local"] {
            #expect(!HostRules.isAccepted(host, customHost: nil), "\(host)")
        }
        #expect(HostRules.isAccepted("remote.example.com:443", customHost: "remote.example.com"))
    }

    @Test func normalize() {
        #expect(HostRules.normalize("Mac.LOCAL.:8740") == "mac.local")
        #expect(HostRules.normalize("[::1]:80") == "[::1]")
        #expect(HostRules.normalize("host:abc") == "host:abc")
    }
}

@Suite struct LinkTests {
    func authority(_ linkHost: LinkHost, hostName: String = "Studio.local.", ip: String = "192.168.1.20") -> String {
        HostRules.linkAuthority(linkHost: linkHost, hostName: hostName, ip: ip, port: 8740)
    }

    @Test func modes() {
        #expect(authority(.hostName) == "Studio.local:8740")
        #expect(authority(.hostName, hostName: "...") == "192.168.1.20:8740")
        #expect(authority(.ipAddress) == "192.168.1.20:8740")
        #expect(authority(.custom("  HTTPS://remote.example.com  ")) == "remote.example.com:8740")
        #expect(authority(.custom("http://box:9000")) == "box:9000")
        #expect(authority(.custom("[fe80::1]")) == "[fe80::1]:8740")
        #expect(authority(.custom("[fe80::1]:81")) == "[fe80::1]:81")
        #expect(authority(.custom("fe80::1")) == "[fe80::1]:8740")
        #expect(authority(.custom("ftp://nope")) == "Studio.local:8740")
        #expect(authority(.custom("")) == "Studio.local:8740")
        #expect(HostRules.acceptedCustomHost(.custom("http://Box.Example.com:9000")) == "box.example.com")
    }

    @Test func pairingLinkShape() async throws {
        let host = RemotoHost(
            config: HostConfig(port: 8740, dataDir: makeTempDir(), hostName: "Studio.local", linkHost: .ipAddress),
            delegate: nil, driver: FakeInput())
        let info = await host.pairingInfo()
        let parts = info.link.components(separatedBy: "/#pair=")
        #expect(parts.count == 2, "\(info.link)")
        #expect(parts[0].hasPrefix("http://") && parts[0].hasSuffix(":8740"))
        #expect(HostRules.isIPv4(String(parts[0].dropFirst(7).dropLast(5))))
        #expect(parts[1].count == 24 && parts[1].allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        #expect(info.secureAddress.hasPrefix("https://"))
        #expect(info.pin.count == 6)
        #expect(info.expiresInSecs <= 600 && info.expiresInSecs >= 598)
        #expect(info.caFingerprint == "")
    }
}

@Suite struct HTTPRulesTests {
    func head(_ method: HTTPMethod = .GET, _ uri: String = "/", _ headers: [(String, String)]) -> HTTPRequestHead {
        HTTPRequestHead(version: .http1_1, method: method, uri: uri, headers: HTTPHeaders(headers))
    }

    func identity(_ host: String?) -> ClientIdentity { ClientIdentity(ip: "10.0.0.2", secure: false, host: host) }

    @Test func precheckOrder() {
        #expect(HTTPRules.precheck(head(.POST, "/", [("Host", "evil.com")]), identity: identity("evil.com"), customHost: nil)?.status == 405)
        #expect(HTTPRules.precheck(head(.GET, "/", [("Host", "mac.local"), ("Content-Length", "5")]), identity: identity("mac.local"), customHost: nil)?.status == 400)
        #expect(HTTPRules.precheck(head(.GET, "/", [("Host", "mac.local"), ("Transfer-Encoding", "chunked")]), identity: identity("mac.local"), customHost: nil)?.status == 400)
        #expect(HTTPRules.precheck(head(.GET, "/", [("Host", "mac.local"), ("Content-Length", "0")]), identity: identity("mac.local"), customHost: nil) == nil)
        #expect(HTTPRules.precheck(head(.GET, "/", []), identity: identity(nil), customHost: nil)?.status == 421)
        #expect(HTTPRules.precheck(head(.GET, "/", [("Host", "evil.com")]), identity: identity("evil.com"), customHost: nil)?.status == 421)
    }

    @Test func websocketChecks() {
        let base: [(String, String)] = [
            ("Host", "mac.local:8740"), ("Upgrade", "websocket"), ("Connection", "keep-alive, Upgrade"),
            ("Sec-WebSocket-Version", "13"), ("Sec-WebSocket-Key", "abc"),
        ]
        let id = identity("mac.local:8740")
        #expect(HTTPRules.websocketCheck(head(.GET, "/ws", base), identity: id) == nil)
        #expect(HTTPRules.websocketCheck(head(.GET, "/ws", base + [("Origin", "http://MAC.local:8740")]), identity: id) == nil)
        #expect(HTTPRules.websocketCheck(head(.GET, "/ws", base + [("Origin", "http://otro:8740")]), identity: id)?.status == 403)
        #expect(HTTPRules.websocketCheck(head(.GET, "/ws", [("Host", "mac.local")]), identity: id)?.status == 426)
        var v12 = base
        v12[3] = ("Sec-WebSocket-Version", "12")
        let reply = HTTPRules.websocketCheck(head(.GET, "/ws", v12), identity: id)
        #expect(reply?.status == 400)
        #expect(reply?.extraHeaders.contains { $0 == ("Sec-WebSocket-Version", "13") } == true)
        #expect(HTTPRules.websocketCheck(head(.GET, "/ws", Array(base.prefix(4))), identity: id)?.status == 400)
    }

    @Test func keepAliveRules() {
        func ka(_ version: HTTPVersion, _ conn: String?, served: Int = 1, age: Double = 1, open: Int = 1) -> Bool {
            HTTPRules.keepAlive(
                version: version, headers: HTTPHeaders(conn.map { [("Connection", $0)] } ?? []), served: served,
                socketAge: age, openConnections: open)
        }
        #expect(ka(.http1_1, nil))
        #expect(!ka(.http1_1, "close"))
        #expect(!ka(.http1_0, nil))
        #expect(ka(.http1_0, "Keep-Alive"))
        #expect(!ka(.http1_1, nil, served: 200))
        #expect(!ka(.http1_1, nil, age: 120))
        #expect(!ka(.http1_1, nil, open: 96))
    }

    @Test func proxyIdentity() {
        let headers = HTTPHeaders([
            ("Host", "127.0.0.1:8740"), ("X-Forwarded-For", "1.2.3.4, 10.0.0.9:5555"), ("X-Forwarded-Proto", "HTTPS, http"),
            ("X-Forwarded-Host", "phone.example.local, other"),
        ])
        let proxied = HTTPRules.identity(peerIP: "127.0.0.1", tls: false, headers: headers, allowLocalProxy: true)
        #expect(proxied == ClientIdentity(ip: "10.0.0.9", secure: true, host: "phone.example.local"))
        let direct = HTTPRules.identity(peerIP: "::ffff:10.0.0.2", tls: true, headers: headers, allowLocalProxy: true)
        #expect(direct == ClientIdentity(ip: "10.0.0.2", secure: true, host: "127.0.0.1:8740"))
        let off = HTTPRules.identity(peerIP: "127.0.0.1", tls: false, headers: headers, allowLocalProxy: false)
        #expect(off.ip == "127.0.0.1" && !off.secure)
    }

    @Test func responseHeaderOrder() {
        let reply = HTTPReply(status: 200, contentType: "text/plain", body: [1, 2], extraHeaders: [("ETag", "\"x\"")])
        let names = HTTPRules.headers(for: reply, keepAlive: false).map(\.name)
        #expect(
            names == [
                "Content-Type", "Content-Length", "Connection", "X-Content-Type-Options", "Referrer-Policy",
                "X-Frame-Options", "Content-Security-Policy", "ETag",
            ])
        #expect(HTTPRules.reason(421) == "Misdirected Request")
        #expect(HTTPRules.reason(500) == "Error")
    }

    @Test func iconBuckets() {
        #expect(HTTPRules.iconBucket(nil) == 128)
        #expect(HTTPRules.iconBucket("abc") == 128)
        #expect(HTTPRules.iconBucket("123456789") == 128)
        #expect(HTTPRules.iconBucket("10") == 64)
        #expect(HTTPRules.iconBucket("100") == 128)
        #expect(HTTPRules.iconBucket("256") == 256)
        #expect(HTTPRules.iconBucket("300") == 512)
    }

    @Test func queriesAndContentTypes() {
        #expect(HTTPRules.splitTarget("/api/icon?id=a%2Eb&size=3#x") == ("/api/icon", "id=a%2Eb&size=3"))
        #expect(HTTPRules.queryItems("id=a%2Eb&size=3&k=") == ["id": "a.b", "size": "3", "k": ""])
        #expect(HTTPRules.contentType(forExtension: "MJS") == "text/javascript; charset=utf-8")
        #expect(HTTPRules.contentType(forExtension: "webmanifest") == "application/manifest+json")
        #expect(HTTPRules.contentType(forExtension: "bin") == "application/octet-stream")
        #expect(HTTPRules.etag(length: 255, mtimeNanos: 4096) == "\"ff-1000\"")
    }
}

@Suite struct StaticFilesTests {
    func makeRoot() throws -> URL {
        let root = makeTempDir()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try "<html>index</html>".write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try "console.log(1)".write(to: root.appendingPathComponent("assets/x.js"), atomically: true, encoding: .utf8)
        try "self.x=1".write(to: root.appendingPathComponent("sw.js"), atomically: true, encoding: .utf8)
        try "secret".write(to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        return root
    }

    func header(_ reply: HTTPReply, _ name: String) -> String? { reply.extraHeaders.first { $0.0 == name }?.1 }

    @Test func servingRules() throws {
        let root = try makeRoot()
        let asset = StaticFiles.reply(path: "/assets/x.js", ifNoneMatch: nil, webRoot: root)
        #expect(asset.status == 200)
        #expect(asset.contentType == "text/javascript; charset=utf-8")
        #expect(header(asset, "Cache-Control") == "public, max-age=31536000, immutable")
        let etag = try #require(header(asset, "ETag"))
        #expect(etag.hasPrefix("\"e-"))
        let again = StaticFiles.reply(path: "/assets/x.js", ifNoneMatch: etag, webRoot: root)
        #expect(again.status == 304 && again.body.isEmpty)

        let spa = StaticFiles.reply(path: "/no-existe", ifNoneMatch: nil, webRoot: root)
        #expect(spa.status == 200 && String(decoding: spa.body, as: UTF8.self) == "<html>index</html>")
        #expect(header(spa, "Cache-Control") == "no-cache")
        #expect(StaticFiles.reply(path: "/no-existe.js", ifNoneMatch: nil, webRoot: root).status == 404)
        #expect(StaticFiles.reply(path: "/.git/config", ifNoneMatch: nil, webRoot: root).status == 404)
        #expect(StaticFiles.reply(path: "/.env", ifNoneMatch: nil, webRoot: root).status == 404)
        #expect(StaticFiles.reply(path: "/%2e%2e/etc/passwd", ifNoneMatch: nil, webRoot: root).status == 404)
        #expect(StaticFiles.reply(path: "/a%5Cb", ifNoneMatch: nil, webRoot: root).status == 404)
        #expect(StaticFiles.reply(path: "/", ifNoneMatch: nil, webRoot: root).contentType == "text/html; charset=utf-8")
        let sw = StaticFiles.reply(path: "/sw.js", ifNoneMatch: nil, webRoot: root)
        #expect(header(sw, "Service-Worker-Allowed") == "/")
    }

    @Test func placeholderWithoutClient() {
        let reply = StaticFiles.reply(path: "/", ifNoneMatch: nil, webRoot: nil)
        #expect(reply.status == 200 && reply.contentType == "text/html; charset=utf-8")
        #expect(String(decoding: reply.body, as: UTF8.self).contains("web client"))
    }
}
