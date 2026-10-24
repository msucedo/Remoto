import Foundation
import Testing
@testable import RemotoCore

@Suite struct SecretsTests {
    @Test func tokenLengths() {
        #expect(Secrets.randomToken(18).count == 24)
        #expect(Secrets.randomToken(32).count == 43)
        let token = Secrets.randomToken(32)
        #expect(token.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        #expect(Secrets.randomToken(32) != token)
    }

    @Test func hashesAndComparison() {
        #expect(Secrets.sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(Secrets.constantTimeEquals("same", "same"))
        #expect(!Secrets.constantTimeEquals("same", "Same"))
        #expect(!Secrets.constantTimeEquals("short", "longer"))
        #expect(!Secrets.constantTimeEquals([1, 2], [1, 2, 3]))
    }

    @Test func pinsAreNeverGuessable() {
        for pin in ["000000", "111111", "123456", "654321", "012345", "987654", "456789"] {
            #expect(PairingSecret.isGuessable(pin))
        }
        for pin in ["019263", "123457", "890123", "112233"] {
            #expect(!PairingSecret.isGuessable(pin))
        }
        for _ in 0..<500 {
            let pin = PairingSecret.makePin()
            #expect(pin.count == 6 && pin.allSatisfy(\.isASCIIDigit) && !PairingSecret.isGuessable(pin))
        }
    }
}

@Suite struct RateLimiterTests {
    @Test func escalatingLockouts() {
        var limiter = RateLimiter(threshold: 5)
        var now = 1000.0
        for i in 1...5 { #expect(limiter.add("k", now: now) == (i == 5)) }
        #expect(limiter.lockRemaining("k", now: now) == 30)
        now += 31
        #expect(limiter.lockRemaining("k", now: now) == nil)
        for _ in 1...5 { limiter.add("k", now: now) }
        #expect(limiter.lockRemaining("k", now: now) == 60)
        #expect(RateLimiter.lockDuration(lockouts: 0) == 30)
        #expect(RateLimiter.lockDuration(lockouts: 4) == 480)
        #expect(RateLimiter.lockDuration(lockouts: 5) == 900)
        #expect(RateLimiter.lockDuration(lockouts: 9) == 900)
    }

    @Test func resetsAfterAnHourIdle() {
        var limiter = RateLimiter(threshold: 3)
        limiter.add("k", now: 0)
        limiter.add("k", now: 1)
        limiter.add("k", now: 3700)
        #expect(limiter.entries["k"]?.count == 1)
        #expect(limiter.lockRemaining("k", now: 3700) == nil)
    }

    @Test func keys() {
        #expect(RateLimiter.key(for: "192.168.1.5") == "192.168.1.5")
        #expect(RateLimiter.key(for: "::ffff:192.168.1.5") == "192.168.1.5")
        #expect(RateLimiter.key(for: "fe80::1:2:3:4") == RateLimiter.key(for: "fe80::9:9:9:9"))
        #expect(RateLimiter.key(for: "fe80::1") != RateLimiter.key(for: "fe81::1"))
    }

    @Test func retrySecondsRoundUpAndNeverZero() {
        #expect(RateLimiter.retrySeconds(0) == 1)
        #expect(RateLimiter.retrySeconds(0.2) == 1)
        #expect(RateLimiter.retrySeconds(29.1) == 30)
    }

    @Test func pruning() {
        var limiter = RateLimiter(threshold: 5)
        for i in 0..<1100 { limiter.add("ip\(i)", now: Double(i)) }
        limiter.pruneIfNeeded(now: 1200)
        #expect(limiter.entries.count <= RateLimiter.maxKeys)
    }

    @Test func globalWindow() {
        var window = GlobalFailureWindow()
        for i in 0..<19 { window.add(now: Double(i)) }
        #expect(window.lockRemaining(now: 19) == nil)
        window.add(now: 19)
        #expect(window.lockRemaining(now: 20) == 40)
        #expect(window.lockRemaining(now: 61) == nil)
    }
}

@Suite struct PairingTests {
    @Test func codeIsSingleUseAndRotatesPin() {
        var state = PairingState(now: 0)
        let code = state.secret.code
        let pin = state.secret.pin
        #expect(code.count == 24)
        #expect(state.checkCode(code, now: 1) == .ok)
        #expect(state.secret.pin != pin || state.secret.code != code)
        #expect(state.checkCode(code, now: 2) == .denied(.expiredCode))
        #expect(state.checkCode("wrong", now: 2) == .denied(.expiredCode))
    }

    @Test func expiryRotates() {
        var state = PairingState(now: 0)
        let code = state.secret.code
        #expect(state.secret.expiresIn(now: 100) == 500)
        #expect(state.checkCode(code, now: 600) == .denied(.expiredCode))
        #expect(state.secret.code != code)
    }

    @Test func pinWindowAndGrace() {
        var state = PairingState(now: 0)
        #expect(state.checkPin(state.secret.pin, ip: "10.0.0.2", now: 1) == .denied(.pinClosed))
        state.setPinVisible(true, now: 1)
        state.setPinVisible(false, now: 10)
        #expect(state.isPinOpen(now: 110))
        #expect(!state.isPinOpen(now: 191))
        #expect(state.checkPin(state.secret.pin, ip: "10.0.0.2", now: 200) == .denied(.pinClosed))
        #expect(state.checkPin(String(state.secret.pin.prefix(3)) + " " + state.secret.pin.suffix(3), ip: "10.0.0.2", now: 110) == .ok)
    }

    @Test func wrongPinsLockOutAndRetirePin() {
        var state = PairingState(now: 0)
        state.setPinVisible(true, now: 0)
        let pin = state.secret.pin
        for _ in 0..<5 { #expect(state.checkPin("000000", ip: "10.0.0.2", now: 1) == .denied(.wrongPin)) }
        #expect(state.secret.pin != pin)
        #expect(state.checkPin(state.secret.pin, ip: "10.0.0.2", now: 2) == .denied(.blocked, retryAfter: 29))
        #expect(state.checkPin(state.secret.pin, ip: "10.0.0.3", now: 2) == .ok)
        // Second lockout lasts 60 s.
        for _ in 0..<5 { _ = state.checkPin("000000", ip: "10.0.0.2", now: 40) }
        #expect(state.checkPin("000000", ip: "10.0.0.2", now: 40) == .denied(.blocked, retryAfter: 60))
    }

    @Test func globalBlockHitsNewAddresses() {
        var state = PairingState(now: 0)
        state.setPinVisible(true, now: 0)
        for i in 0..<20 { _ = state.checkPin("000000", ip: "10.0.1.\(i)", now: 1) }
        if case .denied(.blocked, let retry) = state.checkPin(state.secret.pin, ip: "10.9.9.9", now: 2) {
            #expect(retry == 59)
        } else {
            Issue.record("expected a global block")
        }
    }

    @Test func approvals() async {
        let manager = PairingManager()
        #expect(await manager.beginApproval(id: 1, ip: "10.0.0.2") == .started)
        #expect(await manager.beginApproval(id: 2, ip: "10.0.0.2") == .denied(.denied(.busy)))
        #expect(await manager.beginApproval(id: 3, ip: "10.0.0.3") == .started)
        #expect(await manager.beginApproval(id: 4, ip: "10.0.0.4") == .denied(.denied(.busy)))
        #expect(await manager.respond(id: 1, allow: false))
        #expect(await manager.waitForDecision(id: 1) == false)
        await manager.endApproval(id: 1, ip: "10.0.0.2", approved: false)
        await manager.endApproval(id: 3, ip: "10.0.0.3", approved: true)
        for id in 10..<12 {
            #expect(await manager.beginApproval(id: UInt64(id), ip: "10.0.0.2") == .started)
            await manager.endApproval(id: UInt64(id), ip: "10.0.0.2", approved: false)
        }
        if case .denied(.denied(.blocked, let retry)) = await manager.beginApproval(id: 20, ip: "10.0.0.2") {
            #expect(retry == 30)
        } else {
            Issue.record("expected an approval lockout")
        }
    }
}

@Suite struct TrustTests {
    @Test func issueVerifyAndNeverStoreToken() async throws {
        let dir = makeTempDir()
        let store = TrustStore(dataDir: dir)
        let token = await store.issue(id: "dev-1", name: "  My\u{200E} Phone ", model: "iPhone", ip: "10.0.0.2")
        #expect(token.count == 43)
        let file = try String(contentsOf: dir.appendingPathComponent("trusted.json"), encoding: .utf8)
        #expect(!file.contains(token))
        #expect(file.contains(Secrets.sha256Hex(token)))
        #expect(file.hasPrefix("{\n  \"version\": 1,\n  \"devices\": ["))
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("trusted.json").path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
        #expect(await store.verify(id: "dev-1", token: token, helloName: "", ip: "10.0.0.3") == "My Phone")
        #expect(await store.verify(id: "dev-2", token: token, helloName: "", ip: "10.0.0.3") == nil)
        #expect(await store.verify(id: "dev-1", token: "nope", helloName: "", ip: "10.0.0.3") == nil)
        #expect(await store.verify(id: "dev-1", token: token, helloName: "New", ip: "10.0.0.3") == "New")
        let reloaded = TrustStore(dataDir: dir)
        #expect(await reloaded.devices().first?.lastAddress == "10.0.0.3")
    }

    @Test func renamedNameSticks() async {
        let store = TrustStore(dataDir: makeTempDir())
        let token = await store.issue(id: "d", name: "Phone", model: "", ip: "1.1.1.1")
        #expect(await store.rename(id: "d", name: "Kitchen"))
        #expect(await store.verify(id: "d", token: token, helloName: "Other", ip: "1.1.1.1") == "Kitchen")
        #expect(await store.devices().first?.name == "Kitchen")
        #expect(await store.entries.first?.name.unicodeScalars.first == "\u{200B}")
    }

    @Test func sixtyFifthDeviceEvictsOldest() {
        var list = TrustedList()
        for i in 0..<64 { _ = list.issue(id: "d\(i)", name: "n", model: "", ip: "", now: Int64(100 + i)) }
        _ = list.issue(id: "new", name: "n", model: "", ip: "", now: 1000)
        #expect(list.entries.count == 64)
        #expect(!list.contains(id: "d0"))
        #expect(list.contains(id: "new"))
    }

    @Test func savesOnlyWhenSomethingChanged() {
        var list = TrustedList()
        let token = list.issue(id: "d", name: "n", model: "", ip: "1.1.1.1", now: 0)
        #expect(list.verify(id: "d", token: token, helloName: "n", ip: "1.1.1.1", now: 10) == .ok(name: "n", needsSave: false))
        #expect(list.verify(id: "d", token: token, helloName: "n", ip: "1.1.1.2", now: 20) == .ok(name: "n", needsSave: true))
        #expect(list.verify(id: "d", token: token, helloName: "n", ip: "1.1.1.2", now: 4000) == .ok(name: "n", needsSave: true))
    }

    @Test func corruptFileIsMovedAside() async throws {
        let dir = makeTempDir()
        try "nope".write(to: dir.appendingPathComponent("trusted.json"), atomically: true, encoding: .utf8)
        let store = TrustStore(dataDir: dir)
        #expect(await store.devices().isEmpty)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("trusted.json.corrupt").path))
    }

    @Test func cleanAndDisplayName() {
        #expect(TextClean.clean("\u{202E}ab\u{0007}c\u{FEFF}", max: 64) == "abc")
        #expect(TextClean.clean("  abcdef  ", max: 3) == "a")
        #expect(TextClean.clean("abcdef", max: 3) == "abc")
        #expect(TextClean.displayName("\u{200B}\u{200C}") == "Unnamed device")
        #expect(TextClean.presented("\u{200B}Kitchen") == "Kitchen")
    }
}

@Suite struct SettingsStoreTests {
    @Test func saveRulesAndPurge() async throws {
        let dir = makeTempDir()
        let store = DeviceSettingsStore(dataDir: dir, trustedIDs: ["a"])
        #expect(await store.save(id: "a", settings: .string("x"), updatedAt: 1) == .rejected("Settings must be an object."))
        let big = JSON.obj([("k", .string(String(repeating: "x", count: 131_072)))])
        if case .rejected = await store.save(id: "a", settings: big, updatedAt: 1) {} else { Issue.record("too big accepted") }
        let blob = JSON.obj([("pointerSpeed", .number("1.5"))])
        #expect(await store.save(id: "a", settings: blob, updatedAt: 10) == .saved)
        #expect(await store.save(id: "a", settings: blob, updatedAt: 10) == .unchanged)
        #expect(await store.save(id: "a", settings: .obj([]), updatedAt: 5) == .unchanged)
        let name = DeviceSettingsStore.fileName(for: "a")
        #expect(name.count == 37)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("device-settings/\(name)").path))
        // A device that is no longer trusted loses its settings at load.
        let purged = DeviceSettingsStore(dataDir: dir, trustedIDs: [])
        #expect(await purged.get("a") == nil)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("device-settings/\(name)").path))
    }
}
