import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import Testing
import X509
@testable import RemotoCore

struct TestHost {
    let host: RemotoHost
    let delegate: FakeDelegate
    let input: FakeInput
    let port: UInt16
    let dataDir: URL

    static func start(_ configure: (inout HostConfig) -> Void = { _ in }) async throws -> TestHost {
        let dir = makeTempDir()
        var config = HostConfig(
            port: 0, dataDir: dir, hostName: "test.local", computerName: "Test Mac", appVersion: "9.9.9")
        configure(&config)
        let delegate = FakeDelegate()
        let input = FakeInput()
        let host = RemotoHost(config: config, delegate: delegate, driver: input)
        delegate.host = host
        let port = try await host.start()
        return TestHost(host: host, delegate: delegate, input: input, port: port, dataDir: dir)
    }

    func connect() async throws -> TestWebSocket { try await TestWebSocket.connect(port: port) }

    func hello(_ auth: JSON, id: String = "phone-1", remember: Bool = false, v: Int = 1, name: String = "Test Phone")
        -> JSON
    {
        .obj([
            ("t", .string("hello")), ("v", .int(v)),
            ("device", .obj([("id", .string(id)), ("name", .string(name)), ("model", .string("iPhone"))])),
            ("auth", auth), ("remember", .bool(remember)),
        ])
    }

    var code: String {
        get async { await host.pairingInfo().link.components(separatedBy: "#pair=").last ?? "" }
    }

    /// Pairs by QR code and returns the open socket and the welcome.
    func pair(id: String = "phone-1", remember: Bool = true) async throws -> (TestWebSocket, JSON) {
        let ws = try await connect()
        try await ws.send(json: hello(.obj([("method", .string("pair")), ("code", .string(await code))]), id: id, remember: remember))
        let welcome = try #require(await ws.expect("welcome"))
        return (ws, welcome)
    }

    func stop() async { await host.shutdown() }
}

@Suite struct IntegrationTests {
    @Test func pairWelcomeTokenAndReconnect() async throws {
        let t = try await TestHost.start()
        let (ws, welcome) = try await t.pair()
        let token = try #require(welcome["token"]?.stringValue)
        #expect(token.count == 43)
        #expect(welcome["host"]?["name"] == .string("Test Mac"))
        #expect(welcome["host"]?["os"] == .string("macOS"))
        #expect(welcome["features"]?["permission"] == .bool(true))
        #expect(welcome["sessionKey"]?.stringValue?.count == 24)
        #expect(welcome["layout"] == nil && welcome["volume"] == nil && welcome["settings"] == nil)
        guard case .object(let members) = welcome else { return }
        #expect(members.map(\.key) == ["t", "v", "host", "sessionKey", "token", "features", "deck", "paused"])

        // Events after welcome: Paired, DevicesChanged, SessionsChanged.
        #expect(await eventually { t.delegate.events.contains(.sessionsChanged) })
        let order = t.delegate.events.filter {
            switch $0 {
            case .paired, .devicesChanged, .sessionsChanged: true
            default: false
            }
        }
        #expect(order == [.paired("Test Phone"), .devicesChanged, .sessionsChanged])
        #expect(t.delegate.events.contains(.pairingChanged))
        let trusted = try String(contentsOf: t.dataDir.appendingPathComponent("trusted.json"), encoding: .utf8)
        #expect(!trusted.contains(token))
        #expect(await t.host.connectedDevices().count == 1)
        await ws.close()

        let again = try await t.connect()
        try await again.send(
            json: t.hello(.obj([("method", .string("token")), ("token", .string(token))]), name: "Renamed"))
        let second = try #require(await again.expect("welcome"))
        #expect(second["token"] == .null)
        #expect(await t.host.trustedDevices().first?.name == "Renamed")

        let other = try await t.connect()
        try await other.send(json: t.hello(.obj([("method", .string("token")), ("token", .string(token))]), id: "phone-2"))
        let denied = await other.next()
        #expect(denied?["reason"] == .string("unknown"))
        await again.close()
        await other.close()
        await t.stop()
    }

    @Test func codeIsSingleUse() async throws {
        let t = try await TestHost.start()
        let code = await t.code
        let first = try await t.connect()
        try await first.send(json: t.hello(.obj([("method", .string("pair")), ("code", .string(code))])))
        let welcome = try #require(await first.expect("welcome"))
        #expect(welcome["token"] == .null)
        #expect(!FileManager.default.fileExists(atPath: t.dataDir.appendingPathComponent("trusted.json").path))
        let second = try await t.connect()
        try await second.send(json: t.hello(.obj([("method", .string("pair")), ("code", .string(code))]), id: "phone-2"))
        #expect(await second.next()?["reason"] == .string("expiredCode"))
        #expect(await second.waitClosed())
        await first.close()
        await second.close()
        await t.stop()
    }

    @Test func wrongPinLocksOutWithRetryAfter() async throws {
        let t = try await TestHost.start()
        let pin = JSON.obj([("method", .string("pin")), ("pin", .string("000000"))])
        let closed = try await t.connect()
        try await closed.send(json: t.hello(pin))
        #expect(await closed.next()?["reason"] == .string("pinClosed"))
        await closed.close()

        await t.host.setPinVisible(true)
        for _ in 0..<5 {
            let ws = try await t.connect()
            try await ws.send(json: t.hello(pin))
            let denied = await ws.next()
            #expect(denied?["reason"] == .string("wrongPin"))
            #expect(denied?["retryAfter"] == nil)
            await ws.close()
        }
        let ws = try await t.connect()
        let realPin = await t.host.pairingInfo().pin
        try await ws.send(json: t.hello(.obj([("method", .string("pin")), ("pin", .string(realPin))])))
        let blocked = await ws.next()
        #expect(blocked?["reason"] == .string("blocked"))
        let retry = try #require(blocked?["retryAfter"]?.unsigned(UInt32.self))
        #expect((25...30).contains(retry))
        await ws.close()
        await t.stop()
    }

    @Test func pinPairingWorksAndCanBeDisabled() async throws {
        let t = try await TestHost.start()
        await t.host.setPinVisible(true)
        let ws = try await t.connect()
        try await ws.send(json: t.hello(.obj([("method", .string("pin")), ("pin", .string(await t.host.pairingInfo().pin))])))
        #expect(await ws.expect("welcome") != nil)
        await ws.close()
        var config = t.host.config
        config.allowPin = false
        config.allowApproval = false
        await t.host.updateConfig(config)
        for auth in [
            JSON.obj([("method", .string("pin")), ("pin", .string("123"))]), JSON.obj([("method", .string("approve"))]),
        ] {
            let c = try await t.connect()
            try await c.send(json: t.hello(auth, id: "phone-x"))
            #expect(await c.next()?["reason"] == .string("rejected"))
            await c.close()
        }
        await t.stop()
    }

    @Test func incompatibleHellos() async throws {
        let t = try await TestHost.start()
        let approve = JSON.obj([("method", .string("approve"))])
        for hello in [t.hello(approve, v: 2), t.hello(approve, id: "has space"), t.hello(approve, id: String(repeating: "x", count: 129))] {
            let ws = try await t.connect()
            try await ws.send(json: hello)
            let denied = await ws.next()
            #expect(denied?["reason"] == .string("incompatible"))
            #expect(await ws.waitClosed())
            await ws.close()
        }
        let ws = try await t.connect()
        try await ws.send(#"{"t":"ping","id":1}"#)
        let bye = await ws.next()
        #expect(bye?["t"] == .string("bye") && bye?["reconnect"] == .bool(false))
        await ws.close()
        await t.stop()
    }

    @Test func approvalFlow() async throws {
        let t = try await TestHost.start()
        let ws = try await t.connect()
        try await ws.send(json: t.hello(.obj([("method", .string("approve"))])))
        #expect(await ws.next()?["t"] == .string("pending"))
        try await ws.send(#"{"t":"ping","id":"p"}"#)
        #expect(await ws.next()?["t"] == .string("pong"))
        let request = await eventually {
            t.delegate.events.contains { if case .approvalRequested = $0 { true } else { false } }
        }
        #expect(request)
        let id = t.delegate.events.compactMap { event -> UInt64? in
            if case .approvalRequested(let r) = event { return r.id }
            return nil
        }.first ?? 0
        // A second request from the same address while one is pending is busy.
        let busy = try await t.connect()
        try await busy.send(json: t.hello(.obj([("method", .string("approve"))]), id: "phone-2"))
        #expect(await busy.next()?["reason"] == .string("busy"))
        await busy.close()

        await t.host.respondApproval(id: id, allow: false)
        #expect(await ws.next()?["reason"] == .string("rejected"))
        #expect(await eventually { t.delegate.events.contains(.approvalEnded(id)) })
        await ws.close()

        t.delegate.autoApprove = true
        let ok = try await t.connect()
        try await ok.send(json: t.hello(.obj([("method", .string("approve"))]), remember: true))
        #expect(await ok.expect("welcome")?["token"]?.stringValue?.count == 43)
        await ok.close()
        await t.stop()
    }

    @Test func sessionMessages() async throws {
        let t = try await TestHost.start()
        let (ws, _) = try await t.pair()
        try await ws.send(#"{"t":"ping","id":"x"}"#)
        #expect(await ws.expect("pong")?["id"] == .string("x"))

        // Malformed JSON is ignored, releases input, and the session stays open.
        try await ws.send("{oops")
        try await ws.send(#"{"t":"ping","id":2}"#)
        #expect(await ws.expect("pong")?["id"] == .int(2))
        #expect(t.input.inputs.contains(.release))

        try await ws.send(#"{"t":"key","code":0,"down":true,"repeat":true}"#)
        try await ws.send(#"{"t":"tap","code":300}"#)
        try await ws.send(#"{"t":"tap","code":1,"mods":32}"#)
        try await ws.sendBinary(BinaryFrame.move(dx: 3, dy: 4).bytes)
        try await ws.sendBinary([0x01, 0, 0])
        try await ws.send(#"{"t":"ping","id":3}"#)
        _ = await ws.expect("pong")
        #expect(t.input.inputs.contains(.key(code: 0, down: true, mods: 0, repeats: true)))
        #expect(t.input.inputs.contains(.move(dx: 3, dy: 4)))
        #expect(!t.input.inputs.contains { if case .tap = $0 { true } else { false } })
        #expect(t.input.aliveCount >= 2)

        try await ws.send(json: .obj([("t", .string("text")), ("text", .string(String(repeating: "a", count: 65_537)))]))
        #expect(await ws.expect("notice")?["code"] == .string("tooLong"))

        try await ws.send(#"{"t":"action","action":{"kind":"system","name":"copy"},"id":1}"#)
        #expect(await ws.expect("actionResult")?["ok"] == .bool(true))
        #expect(t.input.inputs.contains(.tapChar(code: 0x08, mods: 1, char: "c")))
        try await ws.send(#"{"t":"action","action":{"kind":"system","name":"lockScreen"},"id":2}"#)
        #expect(await ws.expect("actionResult")?["ok"] == .bool(true))
        #expect(t.delegate.calls.contains("runNative lockScreen"))

        try await ws.send(#"{"t":"apps"}"#)
        #expect(await ws.expect("apps")?["apps"]?.arrayValue?.count == 1)

        await t.host.setVolumeState(value: 2, muted: false)
        #expect(await ws.expect("volume")?["value"] == .int(1))
        await t.host.clearVolumeState()
        #expect(await ws.expect("volumeUnavailable") != nil)

        try await ws.send(#"{"t":"settingsSave","settings":{"a":1},"updatedAt":5}"#)
        try await ws.send(#"{"t":"settingsList"}"#)
        #expect(await ws.expect("settingsList")?["devices"] == .array([]))
        await ws.close()

        let token = try #require(await t.host.trustedDevices().first?.id)
        #expect(token == "phone-1")
        await t.stop()
    }

    @Test func pauseStopsDelayAndIsBroadcast() async throws {
        let t = try await TestHost.start()
        let (ws, _) = try await t.pair()
        try await ws.send(#"{"t":"action","action":{"kind":"delay","ms":3000},"id":"d"}"#)
        try await Task.sleep(for: .milliseconds(200))
        await t.host.setPaused(true)
        #expect(await ws.expect("paused")?["paused"] == .bool(true))
        let result = await ws.expect("actionResult")
        #expect(result?["id"] == .string("d") && result?["ok"] == .bool(false))
        try await ws.send(#"{"t":"text","text":"hi"}"#)
        #expect(await ws.expect("notice")?["code"] == .string("paused"))
        #expect(t.input.pausedCalls == [true])
        await ws.close()
        await t.stop()
    }

    @Test func stopSaysByeWithReconnect() async throws {
        let t = try await TestHost.start()
        let (ws, _) = try await t.pair()
        await t.host.stop()
        let bye = await ws.expect("bye")
        #expect(bye?["reconnect"] == .bool(true))
        #expect(await ws.waitClosed())
        #expect(await eventually { t.delegate.events.last == .stopped })
        await ws.close()
        await t.stop()
    }

    @Test func forgetDeviceSaysByeAndDropsSettings() async throws {
        let t = try await TestHost.start()
        let (ws, _) = try await t.pair()
        try await ws.send(#"{"t":"settingsSave","settings":{"a":1},"updatedAt":5}"#)
        try await ws.send(#"{"t":"ping","id":1}"#)
        _ = await ws.expect("pong")
        await t.host.forgetDevice(id: "phone-1")
        let bye = await ws.expect("bye")
        #expect(bye?["reconnect"] == .bool(false))
        #expect(await t.host.trustedDevices().isEmpty)
        await ws.close()
        await t.stop()
    }

    @Test func settingsComeBackInWelcome() async throws {
        let t = try await TestHost.start()
        let (ws, welcome) = try await t.pair()
        let token = try #require(welcome["token"]?.stringValue)
        try await ws.send(#"{"t":"settingsSave","settings":{"pointerSpeed":1.5},"updatedAt":42}"#)
        try await ws.send(#"{"t":"ping","id":1}"#)
        _ = await ws.expect("pong")
        await ws.close()
        let again = try await t.connect()
        try await again.send(json: t.hello(.obj([("method", .string("token")), ("token", .string(token))])))
        let second = try #require(await again.expect("welcome"))
        #expect(second["settings"]?.compact == #"{"settings":{"pointerSpeed":1.5},"updatedAt":42}"#)
        await again.close()
        await t.stop()
    }

    @Test func silentSessionIsClosedWithoutBye() async throws {
        let t = try await TestHost.start()
        let (ws, _) = try await t.pair()
        let clock = ContinuousClock()
        let start = clock.now
        let item = await ws.inbox.next(timeout: .seconds(12))
        #expect(item == .closed)
        #expect(clock.now - start > .seconds(7))
        await ws.close()
        await t.stop()
    }

    // MARK: HTTP on the same port

    @Test func httpChecks() async throws {
        let t = try await TestHost.start()
        let evil = try await rawHTTP(port: t.port, "GET / HTTP/1.1\r\nHost: evil.example.com\r\n\r\n")
        #expect(evil.status == 421)
        #expect(evil.raw.hasPrefix("HTTP/1.1 421 Misdirected Request\r\n"))
        #expect(evil.header("Content-Security-Policy") == HTTPRules.csp)
        #expect(evil.header("X-Frame-Options") == "DENY")
        #expect(evil.headers.map(\.0).prefix(7) == [
            "Content-Type", "Content-Length", "Connection", "X-Content-Type-Options", "Referrer-Policy",
            "X-Frame-Options", "Content-Security-Policy",
        ])
        let post = try await rawHTTP(port: t.port, "POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n")
        #expect(post.status == 405)
        let body = try await rawHTTP(port: t.port, "GET / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\nhello")
        #expect(body.status == 400)
        let noUpgrade = try await rawHTTP(port: t.port, "GET /ws HTTP/1.1\r\nHost: localhost\r\n\r\n")
        #expect(noUpgrade.status == 426)
        let info = try await rawHTTP(port: t.port, "GET /api/info HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        #expect(info.status == 200)
        #expect(String(decoding: info.body, as: UTF8.self) == #"{"name":"Test Mac","protocol":1,"secure":false,"version":"9.9.9"}"#)
        #expect(info.header("Connection") == "close")
        let crt = try await rawHTTP(port: t.port, "GET /remoto.crt HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        #expect(crt.status == 200 && crt.header("Content-Type") == "application/x-x509-ca-cert")
        #expect([UInt8](t.host.caCertificate()) == crt.body)
        // Two pipelined requests on one keep-alive socket.
        let pipelined = try await rawHTTP(
            port: t.port,
            "GET /api/info HTTP/1.1\r\nHost: localhost\r\n\r\nGET /api/info HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        #expect(pipelined.raw.components(separatedBy: "HTTP/1.1 200 OK").count == 3)
        await t.stop()
    }

    /// BoringSSL's verifier can't evaluate IP name constraints, so the chain is
    /// checked with swift-certificates (RFC 5280 + server identity) instead.
    @Test(arguments: [("localhost", nil), (nil, "127.0.0.1")] as [(String?, String?)])
    func httpsOnTheSamePortVerifiesAgainstTheCA(hostname: String?, ip: String?) async throws {
        let t = try await TestHost.start()
        let ca = try Certificate(derEncoded: [UInt8](t.host.caCertificate()))
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.certificateVerification = .fullVerification
        tls.applicationProtocols = ["http/1.1"]
        let context = try NIOSSLContext(configuration: tls)
        let verified = Locked(false)
        let response = try await rawHTTP(
            port: t.port, "GET /api/info HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n", tls: context,
            serverName: hostname,
            verify: { presented in
                guard let first = presented.first, let der = try? first.toDERBytes(),
                    let leaf = try? Certificate(derEncoded: der)
                else { return false }
                var verifier = Verifier(rootCertificates: CertificateStore([ca])) {
                    RFC5280Policy()
                    ServerIdentityPolicy(serverHostname: hostname, serverIP: ip)
                }
                let result = await verifier.validate(leaf: leaf, intermediates: CertificateStore())
                if case .validCertificate = result {
                    verified.set(true)
                    return true
                }
                return false
            })
        #expect(verified.value)
        #expect(response.status == 200)
        #expect(String(decoding: response.body, as: UTF8.self).contains(#""secure":true"#))
        #expect(await t.host.pairingInfo().caFingerprint.count == 95)
        await t.stop()
    }

    @Test func iconsNeedASessionKeyAndAreCached() async throws {
        let t = try await TestHost.start()
        let denied = try await rawHTTP(port: t.port, "GET /api/icon?id=a HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        #expect(denied.status == 403)
        let (ws, welcome) = try await t.pair()
        let key = try #require(welcome["sessionKey"]?.stringValue)
        for _ in 0..<2 {
            let ok = try await rawHTTP(
                port: t.port, "GET /api/icon?id=com.x&size=100&k=\(key) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
            #expect(ok.status == 200 && ok.header("Content-Type") == "image/png")
            #expect(ok.header("Cache-Control") == "private, max-age=86400")
        }
        let big = try await rawHTTP(
            port: t.port, "GET /api/icon?id=com.x&size=300&k=\(key) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        #expect(big.status == 200)
        #expect(t.delegate.calls.filter { $0.hasPrefix("appIcon") } == ["appIcon com.x 128", "appIcon com.x 512"])
        let badID = try await rawHTTP(port: t.port, "GET /api/icon?k=\(key) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        #expect(badID.status == 400)
        await ws.close()
        await t.stop()
    }

    @Test func seventeenthConnectionFromOneAddressIsClosed() async throws {
        let t = try await TestHost.start()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        var channels: [Channel] = []
        for _ in 0..<16 {
            channels.append(try await ClientBootstrap(group: group).connect(host: "127.0.0.1", port: Int(t.port)).get())
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(channels.allSatisfy { $0.isActive })
        let extra = try await ClientBootstrap(group: group).connect(host: "127.0.0.1", port: Int(t.port)).get()
        let closed = await eventually(timeout: .seconds(2)) { !extra.isActive }
        #expect(closed)
        for channel in channels { try? await channel.close() }
        try await group.shutdownGracefully()
        await t.stop()
    }

    @Test func takenPreferredPortMovesOn() async throws {
        // Stay below the ephemeral range, where parallel tests open client sockets.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        var blocker: Channel?
        var taken = 0
        for _ in 0..<20 {
            let candidate = Int.random(in: 20_000..<40_000)
            if let channel = try? await ServerBootstrap(group: group).bind(host: "0.0.0.0", port: candidate).get() {
                blocker = channel
                taken = candidate
                break
            }
        }
        let channel = try #require(blocker)
        let t = try await TestHost.start { $0.port = UInt16(taken) }
        #expect(t.port != UInt16(taken))
        #expect(t.port > UInt16(taken) && t.port < UInt16(taken + 20))
        #expect(await eventually { t.delegate.events.contains(.started(port: t.port, preferredPortTaken: true)) })
        await t.stop()
        try await channel.close()
        try await group.shutdownGracefully()
    }
}

@Suite struct MoreSessionTests {
    @Test func pasteUsesClipboardAndCommandV() async throws {
        let t = try await TestHost.start()
        let (ws, _) = try await t.pair()
        try await ws.send(#"{"t":"text","text":"pasted","mode":"paste"}"#)
        #expect(await eventually { t.delegate.calls.contains("pasteEnd") })
        let calls = t.delegate.calls.filter { $0.hasPrefix("paste") }
        #expect(calls == ["pasteBegin", "pasteEnd"])
        #expect(t.input.inputs.contains(.tapChar(code: 0x09, mods: Mods.cmd, char: "v")))
        await ws.close()
        await t.stop()
    }

    @Test func thirtyThirdWaitingActionIsRefused() async throws {
        let t = try await TestHost.start()
        let (ws, _) = try await t.pair()
        try await ws.send(#"{"t":"action","action":{"kind":"delay","ms":1500},"id":"slow"}"#)
        try await Task.sleep(for: .milliseconds(100))
        for i in 0..<33 {
            try await ws.send(#"{"t":"action","action":{"kind":"media","key":"mute"},"id":\#(i)}"#)
        }
        var refused: [JSON] = []
        var okCount = 0
        while let result = await ws.expect("actionResult", timeout: .seconds(4)) {
            if result["ok"] == .bool(false) { refused.append(result["id"] ?? .null) } else { okCount += 1 }
            if refused.count + okCount == 34 { break }
        }
        #expect(refused == [.int(32)])
        #expect(okCount == 33)
        await ws.close()
        await t.stop()
    }

    @Test func settingsRulesForSessionsThatArentRemembered() async throws {
        let t = try await TestHost.start()
        let (guest, _) = try await t.pair(id: "guest", remember: false)
        try await guest.send(#"{"t":"settingsSave","settings":{"a":1},"updatedAt":5}"#)
        try await guest.send(#"{"t":"settingsCopy","from":"guest"}"#)
        #expect(await guest.expect("notice")?["code"] == .string("settings"))
        #expect(!FileManager.default.fileExists(atPath: t.dataDir.appendingPathComponent("device-settings").path))
        await guest.close()

        let (a, _) = try await t.pair(id: "a")
        try await a.send(#"{"t":"settingsSave","settings":{"n":1},"updatedAt":10}"#)
        try await a.send(#"{"t":"settingsCopy","from":"nobody"}"#)
        #expect(await a.expect("notice")?["code"] == .string("settings"))
        let (b, _) = try await t.pair(id: "b")
        try await b.send(#"{"t":"settingsSave","settings":{"n":2},"updatedAt":20}"#)
        try await b.send(#"{"t":"ping","id":0}"#)
        _ = await b.expect("pong")
        let (c, _) = try await t.pair(id: "c")
        try await c.send(#"{"t":"settingsList"}"#)
        let list = try #require(await c.expect("settingsList")?["devices"]?.arrayValue)
        #expect(list.compactMap { $0["id"]?.stringValue } == ["b", "a"])
        try await c.send(#"{"t":"settingsCopy","from":"b"}"#)
        #expect(await c.expect("settings")?.compact == #"{"t":"settings","settings":{"n":2},"updatedAt":20}"#)

        await t.host.forgetDevice(id: "b")
        try await c.send(#"{"t":"settingsCopy","from":"b"}"#)
        #expect(await c.expect("notice")?["code"] == .string("settings"))
        for ws in [a, b, c] { await ws.close() }
        await t.stop()
    }

    @Test func voiceOffAndBroadcasts() async throws {
        let t = try await TestHost.start { $0.voiceAvailable = false }
        let (ws, welcome) = try await t.pair()
        #expect(welcome["features"]?["voice"] == .bool(false))
        try await ws.send(#"{"t":"voiceStart","locale":"es-MX"}"#)
        #expect(await ws.expect("voice")?["state"] == .string("unavailable"))
        #expect(!t.delegate.calls.contains("voiceBegin"))

        await t.host.appsChanged()
        #expect(await ws.expect("appsChanged") != nil)
        var config = t.host.config
        config.voiceAvailable = true
        config.allowShell = true
        await t.host.updateConfig(config)
        let features = await ws.expect("features")?["features"]
        #expect(features?["voice"] == .bool(true) && features?["shell"] == .bool(true))

        try await ws.send(#"{"t":"voiceStart"}"#)
        #expect(await eventually { t.delegate.calls.contains("voiceBegin") })
        try await ws.sendBinary([0x10, 1, 0, 2, 0])
        try await ws.send(#"{"t":"ping","id":9}"#)
        _ = await ws.expect("pong")
        t.host.voiceUpdate(session: try #require(await t.host.connectedDevices().first?.session), VoiceUpdate(state: .stopped, text: "hola", isFinal: true))
        let voice = await ws.expect("voice")
        #expect(voice?.compact == #"{"t":"voice","state":"stopped","text":"hola","final":true}"#)
        #expect(await eventually { t.delegate.calls.contains("voiceFeed 4") })
        await ws.close()
        #expect(await eventually { await t.host.connectedDevices().isEmpty })
        await t.stop()
    }
}

/// Fixes from the security review.
@Suite struct HardeningTests {
    @Test func connectionLimitGroupsIPv6By64() {
        let tracker = ConnectionTracker()
        for i in 0..<16 { #expect(tracker.admit(ip: "fd00:1:2:3::\(i + 1)", channel: nil, allowLocalProxy: false) != nil) }
        #expect(tracker.admit(ip: "fd00:1:2:3:ffff::9", channel: nil, allowLocalProxy: false) == nil)
        #expect(tracker.admit(ip: "fd00:1:2:4::1", channel: nil, allowLocalProxy: false) != nil)
        for _ in 0..<16 { _ = tracker.admit(ip: "::ffff:10.0.0.7", channel: nil, allowLocalProxy: false) }
        #expect(tracker.admit(ip: "10.0.0.7", channel: nil, allowLocalProxy: false) == nil)
    }

    @Test func pipelinedFloodIsCutOff() async throws {
        let t = try await TestHost.start()
        let one = "GET /api/info HTTP/1.1\r\nHost: localhost\r\n\r\n"
        let response = try await rawHTTP(port: t.port, String(repeating: one, count: 50))
        let answered = response.raw.components(separatedBy: "HTTP/1.1 200 OK").count - 1
        #expect(answered >= 1 && answered <= HTTPHandler.maxQueued + 1)
        await t.stop()
    }

    @Test func bodiesAreRefusedAtTheHead() async throws {
        let t = try await TestHost.start()
        let clock = ContinuousClock()
        let start = clock.now
        // The body never comes; the answer must not wait for it.
        let big = try await rawHTTP(port: t.port, "GET / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1000000\r\n\r\n")
        #expect(big.status == 400)
        let chunked = try await rawHTTP(port: t.port, "GET / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n")
        #expect(chunked.status == 400)
        let post = try await rawHTTP(port: t.port, "POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 50\r\n\r\n")
        #expect(post.status == 405)
        #expect(clock.now - start < .seconds(3))
        await t.stop()
    }

    @Test func bigMessageBeforeHelloCloses() async throws {
        let t = try await TestHost.start()
        let ws = try await t.connect()
        try await ws.send(json: .obj([("t", .string("ping")), ("id", .string(String(repeating: "x", count: 9000)))]))
        #expect(await ws.waitClosed())
        await ws.close()
        await t.stop()
    }

    @Test func messageLimitsAfterHello() async throws {
        let t = try await TestHost.start()
        let (ws, _) = try await t.pair()
        // 200 KiB is fine once authenticated.
        let id = String(repeating: "y", count: 200_000)
        try await ws.send(json: .obj([("t", .string("ping")), ("id", .string(id))]))
        #expect(await ws.expect("pong")?["id"] == .string(id))
        // Frames over the cap close the connection.
        try await ws.send(String(repeating: "z", count: HTTPHandler.maxFrameSize + 1))
        #expect(await ws.waitClosed())
        await ws.close()
        await t.stop()
    }

    @Test func settingsListNeedsARememberedSession() async throws {
        let t = try await TestHost.start()
        let (ws, _) = try await t.pair(remember: false)
        try await ws.send(#"{"t":"settingsList"}"#)
        let notice = await ws.expect("notice")
        #expect(notice?["code"] == .string("settings") && notice?["level"] == .string("warning"))
        await ws.close()
        await t.stop()
    }

    @Test func turningShellOffEndsRunningCommands() async throws {
        let t = try await TestHost.start { $0.allowShell = true }
        let (ws, _) = try await t.pair()
        let pidFile = t.dataDir.appendingPathComponent("shell.pid")
        let command = "echo $$ > '\(pidFile.path)'; exec sleep 30"
        try await ws.send(json: .obj([
            ("t", .string("action")), ("id", .int(1)),
            ("action", .obj([("kind", .string("shell")), ("command", .string(command))])),
        ]))
        #expect(await ws.expect("actionResult")?["ok"] == .bool(true))
        #expect(await eventually { (try? String(contentsOf: pidFile, encoding: .utf8)) != nil })
        let pid = try #require(Int32((try String(contentsOf: pidFile, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) == 0)
        var config = t.host.config
        config.allowShell = false
        await t.host.updateConfig(config)
        #expect(await eventually(timeout: .seconds(4)) { kill(pid, 0) != 0 })
        await ws.close()
        await t.stop()
    }

    @Test func approvalFlagsLookalikeNames() async throws {
        let t = try await TestHost.start()
        let (paired, _) = try await t.pair(id: "real")
        await paired.close()
        let ws = try await t.connect()
        try await ws.send(json: t.hello(.obj([("method", .string("approve"))]), id: "fake", name: "test phone"))
        #expect(await ws.next()?["t"] == .string("pending"))
        let flagged = await eventually {
            t.delegate.events.contains { if case .approvalRequested(let r) = $0 { r.nameMatchesTrustedDevice } else { false } }
        }
        #expect(flagged)
        await ws.close()
        await t.stop()
    }

    @Test func persistenceHardening() async throws {
        let dir = makeTempDir()
        let folder = dir.appendingPathComponent("open")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try AtomicFile.ensureDirectory(folder)
        let attrs = try FileManager.default.attributesOfItem(atPath: folder.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o700)

        let good = #"{"id":"ok","name":"n","model":"","pairedAt":1,"lastSeen":2,"lastAddress":"","tokenHash":"\#(Secrets.sha256Hex("t"))"}"#
        let bad = #"{"id":"bad","name":"n","pairedAt":1,"lastSeen":2,"tokenHash":"not-a-hash"}"#
        try #"{"version":1,"devices":[\#(good),\#(bad),42]}"#.write(
            to: dir.appendingPathComponent("trusted.json"), atomically: true, encoding: .utf8)
        let store = TrustStore(dataDir: dir)
        #expect(await store.devices().map(\.id) == ["ok"])
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("trusted.json.corrupt").path))
    }

    @Test func identityRenewalIsDueNearExpiry() throws {
        let dir = makeTempDir()
        let names = ["127.0.0.1", "localhost"]
        let (fresh, _) = try TLSIdentityStore.load(dataDir: dir, names: names)
        #expect(!fresh.needsRenewal())
        #expect(fresh.needsRenewal(now: Date().addingTimeInterval(370 * 86_400)))
    }
}
