import Foundation

/// The Remoto service: web server, pairing, sessions, deck and settings.
/// Create one per app, keep a strong reference to your delegate (the host
/// holds it weakly), call `start()`, and drive it with the methods below.
/// Everything is safe to call from any thread or actor.
public final class RemotoHost: Sendable {
    /// Version of this core library.
    public static let coreVersion = "0.1.0"
    /// Protocol version spoken on `/ws` and reported by `/api/info`.
    public static let protocolVersion = 1

    let core: HostCore
    private let lifecycle = Lifecycle()
    private let relay: AsyncStream<RelayItem>.Continuation
    private let relayTask: Task<Void, Never>
    private let shutDown = Locked(false)

    private enum RelayItem: Sendable {
        case voice(UInt64, VoiceUpdate)
        case notice(UInt64, InputNotice)
    }

    private actor Lifecycle {
        var listener: Listener?
        var housekeeping: Task<Void, Never>?
        func set(_ listener: Listener?, _ housekeeping: Task<Void, Never>?) {
            self.listener = listener
            self.housekeeping = housekeeping
        }
        func take() -> (Listener?, Task<Void, Never>?) {
            defer {
                listener = nil
                housekeeping = nil
            }
            return (listener, housekeeping)
        }
    }

    /// Loads trusted devices, per-device settings and the deck, and starts the
    /// input engine. `input` defaults to the real engine posting system events.
    public convenience init(config: HostConfig, delegate: any HostDelegate, input: InputBackend = .engine(.system)) {
        let relay = NoticeRelay()
        let driver: InputDriver =
            switch input {
            case .engine(let sink): EngineDriver(sink: sink, relay: relay)
            case .discard: DiscardDriver()
            }
        self.init(config: config, delegate: delegate, driver: driver, noticeRelay: relay)
    }

    init(config: HostConfig, delegate: (any HostDelegate)?, driver: InputDriver, noticeRelay: NoticeRelay? = nil) {
        let core = HostCore(config: config, delegate: delegate, input: driver)
        self.core = core
        let (stream, continuation) = AsyncStream.makeStream(of: RelayItem.self)
        relay = continuation
        relayTask = Task {
            for await item in stream {
                switch item {
                case .voice(let session, let update):
                    await core.sessions.get(session)?.post(.voiceUpdate(update))
                case .notice(let session, let notice):
                    await Self.deliver(notice, session: session, core: core)
                }
            }
        }
        noticeRelay?.set { [continuation] session, notice in continuation.yield(.notice(session, notice)) }
    }

    deinit {
        relay.finish()
        relayTask.cancel()
        if !shutDown.value { core.input.shutdown() }
    }

    private static func deliver(_ notice: InputNotice, session: UInt64, core: HostCore) async {
        switch notice {
        case .accessibility:
            let text = "Remoto needs Accessibility permission on the Mac to control it."
            await core.sessions.get(session)?.writer.send(.notice(.warning, code: .permission, message: text))
            core.emit(.notice(text))
        case .secureInput:
            let text = "A password field on the Mac is blocking typing."
            await core.sessions.get(session)?.writer.send(.notice(.warning, code: .secureInput, message: text))
        }
    }

    // MARK: Lifecycle

    /// Opens the listeners and returns the port. Idempotent while running.
    @discardableResult
    public func start() async throws -> UInt16 {
        if let port = core.runtime.withLock({ $0.running ? $0.port : nil }) { return port }
        let config = core.config
        do {
            let addresses = Addresses.current()
            let names = ServerNames.compute(hostName: config.hostName, addresses: addresses.map(\.ip))
            let identity = await Self.loadIdentity(dataDir: config.dataDir, names: names)
            let (listener, taken) = try await Listener.open(core: core, preferred: config.port)
            core.runtime.withLock {
                $0.running = true
                $0.port = listener.port
                $0.preferredPortTaken = taken
                $0.addresses = addresses
                $0.serverNames = names
                if let identity { $0.identity = identity }
            }
            let core = self.core
            let housekeeping = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled else { break }
                    await Self.housekeep(core)
                }
            }
            await lifecycle.set(listener, housekeeping)
            core.emit(.started(port: listener.port, preferredPortTaken: taken))
            return listener.port
        } catch {
            let message = (error as? HostError)?.message ?? "\(error)"
            Log.error("host", "start failed: \(message)")
            core.emit(.failed(message))
            throw HostError(message)
        }
    }

    /// Says goodbye to every phone (they will reconnect later), releases all
    /// input and closes the server.
    public func stop() async {
        guard core.runtime.value.running else { return }
        let sessions = await core.sessions.all
        for session in sessions {
            session.post(.bye(reason: "The Mac stopped sharing control.", reconnect: true))
        }
        // Give the goodbyes a moment to go out.
        for _ in 0..<20 where !(await core.sessions.isEmpty) {
            try? await Task.sleep(for: .milliseconds(50))
        }
        for session in sessions { core.input.forget(session: session.id) }
        let (listener, housekeeping) = await lifecycle.take()
        housekeeping?.cancel()
        await listener?.close(connections: core.connections)
        core.runtime.withLock { $0.running = false }
        core.emit(.sessionsChanged)
        core.emit(.stopped)
    }

    /// Stops the server and the input engine for good.
    public func shutdown() async {
        await stop()
        let first = shutDown.withLock { done -> Bool in
            defer { done = true }
            return !done
        }
        if first { core.input.shutdown() }
    }

    public var isRunning: Bool { core.runtime.value.running }

    /// The port in use (0 when stopped).
    public var port: UInt16 { core.runtime.withLock { $0.running ? $0.port : 0 } }

    public func updateConfig(_ config: HostConfig) async {
        let old = core.configBox.withLock { current -> HostConfig in
            defer { current = config }
            return current
        }
        if old.allowShell != config.allowShell || old.voiceAvailable != config.voiceAvailable {
            await core.broadcastFeatures()
        }
        if old.hostName != config.hostName || old.linkHost != config.linkHost {
            core.emit(.pairingChanged)
        }
    }

    public var config: HostConfig { core.config }

    // MARK: Pairing (SPEC §3.2, §6)

    public func pairingInfo() async -> PairingInfo {
        _ = await core.pairing.rotateIfExpired()
        let secret = await core.pairing.secret
        let config = core.config
        let runtime = core.runtime.value
        let addresses = runtime.running ? runtime.addresses : Addresses.current()
        let port = runtime.running ? runtime.port : config.port
        let ip = addresses.first?.ip ?? "127.0.0.1"
        let authority = HostRules.linkAuthority(linkHost: config.linkHost, hostName: config.hostName, ip: ip, port: port)
        let address = "http://\(authority)"
        return PairingInfo(
            link: "\(address)/#pair=\(secret.code)", address: address, secureAddress: "https://\(authority)",
            pin: secret.pin, expiresInSecs: secret.expiresIn(now: Mono.now()), port: port,
            addresses: addresses.map(\.ip), vpnAddresses: addresses.filter(\.vpn).map(\.ip),
            caFingerprint: runtime.identity?.caFingerprint ?? "")
    }

    /// New code and PIN.
    public func renewPairing() async {
        await core.pairing.renew()
        core.emit(.pairingChanged)
    }

    /// Tell the core whether the card showing the PIN is on screen.
    public func setPinVisible(_ visible: Bool) async {
        await core.pairing.setPinVisible(visible)
    }

    /// DER of the local CA (empty without a TLS identity).
    public func caCertificate() -> Data {
        Data(core.runtime.value.identity?.caDER ?? [])
    }

    public func respondApproval(id: UInt64, allow: Bool) async {
        _ = await core.pairing.respond(id: id, allow: allow)
    }

    // MARK: Devices (SPEC §7)

    public func connectedDevices() async -> [ConnectedDevice] {
        await core.sessions.all.map(\.device)
    }

    public func trustedDevices() async -> [TrustedDevice] {
        await core.trust.devices()
    }

    public func disconnect(session: UInt64) async {
        await core.sessions.get(session)?.post(.bye(reason: "The Mac closed this connection.", reconnect: false))
    }

    public func forgetDevice(id: String) async {
        _ = await core.trust.remove(id: id)
        await core.settings.remove(id)
        for session in await core.sessions.remembered(deviceID: id) {
            session.post(.bye(reason: "This device was removed on the Mac. Pair it again to reconnect.", reconnect: false))
        }
        core.emit(.devicesChanged)
    }

    public func forgetAllDevices() async {
        await core.trust.removeAll()
        await core.settings.removeAll()
        for session in await core.sessions.remembered(deviceID: nil) {
            session.post(.bye(reason: "All devices were removed on the Mac. Pair again to reconnect.", reconnect: false))
        }
        core.emit(.devicesChanged)
    }

    public func renameDevice(id: String, name: String) async {
        if await core.trust.rename(id: id, name: name) { core.emit(.devicesChanged) }
    }

    // MARK: Control

    /// Global pause: drops all input, stops running actions and shell commands.
    public func setPaused(_ paused: Bool) async {
        let changed = core.runtime.withLock { state -> Bool in
            defer { state.paused = paused }
            return state.paused != paused
        }
        core.input.setPaused(paused)
        if changed { await core.broadcast(.paused(paused)) }
    }

    public var isPaused: Bool { core.isPaused }

    // MARK: Deck (SPEC §12)

    public func deckJSON() async -> String { await core.deck.exported }

    /// Validates, saves and sends the deck to every phone. Throws `HostError`.
    public func setDeckJSON(_ json: String) async throws {
        do {
            try await core.deck.replace(json: json)
        } catch {
            throw HostError(error.message)
        }
        await core.broadcast(.deck(await core.deck.deck))
    }

    public func resetDeck() async {
        await core.deck.reset()
        await core.broadcast(.deck(await core.deck.deck))
    }

    // MARK: Things the app reports

    /// Installed or running apps changed: drops cached icons and tells phones.
    public func appsChanged() async {
        core.icons.withLock { $0.removeAll() }
        await core.broadcast(.appsChanged)
    }

    /// Accessibility permission changed.
    public func permissionChanged() async {
        await core.broadcastFeatures()
    }

    public func setLayout(_ layout: KeyboardLayout) async {
        core.runtime.withLock { $0.layout = layout }
        core.input.setLayout(layout)
        await core.broadcast(.layout(layout))
    }

    public func setInputTiming(repeatDelayMs: UInt32, repeatIntervalMs: UInt32, doubleClickMs: UInt32) {
        core.input.setTiming(
            InputTiming(repeatDelayMs: repeatDelayMs, repeatIntervalMs: repeatIntervalMs, doubleClickMs: doubleClickMs))
    }

    public func setVolumeState(value: Float, muted: Bool) async {
        let clamped = value.isFinite ? min(max(value, 0), 1) : 0
        let state = VolumeState(value: clamped, muted: muted)
        let changed = core.runtime.withLock { runtime -> Bool in
            defer { runtime.volume = state }
            return runtime.volume != state
        }
        if changed { await core.broadcast(.volume(state)) }
    }

    public func clearVolumeState() async {
        let had = core.runtime.withLock { runtime -> Bool in
            defer { runtime.volume = nil }
            return runtime.volume != nil
        }
        if had { await core.broadcast(.volumeUnavailable) }
    }

    /// Dictation progress for a session. Updates are delivered in call order.
    public func voiceUpdate(session: UInt64, _ update: VoiceUpdate) {
        relay.yield(.voice(session, update))
    }

    /// `debug`, `info`, `warning` or `error`. `mirrorToStderr` also prints log lines.
    public static func initLogging(_ filter: String, mirrorToStderr: Bool = false) {
        Log.configure(filter: filter, mirrorToStderr: mirrorToStderr)
    }

    // MARK: Internals

    private static func loadIdentity(dataDir: URL, names: [String]) async -> TLSIdentity? {
        let result = await Blocking.run { () -> Result<(TLSIdentity, TLSLoadReport), Error> in
            Result { try TLSIdentityStore.load(dataDir: dataDir, names: names) }
        }
        switch result {
        case .success(let (identity, report)):
            if report.newCA { Log.info("tls", "created a new local CA") }
            if report.newLeaf { Log.info("tls", "issued a server certificate for \(names.joined(separator: ", "))") }
            return identity
        case .failure(let error):
            Log.error("tls", "TLS identity unavailable: \(error)")
            return nil
        }
    }

    /// Every 5 s: code/PIN expiry, address changes, certificate names (SPEC §2.1).
    private static func housekeep(_ core: HostCore) async {
        var changed = await core.pairing.rotateIfExpired()
        let addresses = Addresses.current()
        let config = core.config
        let names = ServerNames.compute(hostName: config.hostName, addresses: addresses.map(\.ip))
        let (oldAddresses, oldNames) = core.runtime.withLock { state -> ([LocalAddress], [String]) in
            defer {
                state.addresses = addresses
                state.serverNames = names
            }
            return (state.addresses, state.serverNames)
        }
        if oldAddresses != addresses { changed = true }
        // Reload when the names change, and when the CA or leaf gets close to
        // expiring (the app may run for over a year on the same network).
        let due = core.runtime.value.identity?.needsRenewal() ?? false
        if oldNames != names || due, let identity = await loadIdentity(dataDir: config.dataDir, names: names) {
            // On failure the previous identity stays in place.
            core.runtime.withLock { $0.identity = identity }
        }
        if changed { core.emit(.pairingChanged) }
    }
}
