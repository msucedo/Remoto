import Foundation
import NIOCore
import NIOSSL
import NIOWebSocket

/// Host-wide state that changes at runtime.
struct RuntimeState: Sendable {
    var running = false
    var port: UInt16 = 0
    var preferredPortTaken = false
    var addresses: [LocalAddress] = []
    var serverNames: [String] = []
    var identity: TLSIdentity?
    var paused = false
    var layout: KeyboardLayout?
    var volume: VolumeState?
}

private struct WeakDelegate: Sendable {
    weak var value: (any HostDelegate)?
}

/// Everything the server, sessions and the public `RemotoHost` share.
final class HostCore: Sendable {
    let configBox: Locked<HostConfig>
    let input: InputDriver
    let pairing: PairingManager
    let trust: TrustStore
    let deck: DeckStore
    let settings: DeviceSettingsStore
    let sessions = SessionRegistry()
    let connections = ConnectionTracker()
    let runtime = Locked(RuntimeState())
    let icons = Locked([String: Data]())

    private let delegateBox: Locked<WeakDelegate>
    private let counter = Locked<UInt64>(0)
    private let eventQueue = DispatchQueue(label: "remoto-events", qos: .userInitiated)

    init(config: HostConfig, delegate: (any HostDelegate)?, input: InputDriver) {
        configBox = Locked(config)
        delegateBox = Locked(WeakDelegate(value: delegate))
        self.input = input
        try? AtomicFile.ensureDirectory(config.dataDir)
        pairing = PairingManager()
        trust = TrustStore(dataDir: config.dataDir)
        deck = DeckStore(dataDir: config.dataDir)
        settings = DeviceSettingsStore(dataDir: config.dataDir, trustedIDs: trust.initialIDs)
    }

    var config: HostConfig { configBox.value }
    var delegate: (any HostDelegate)? { delegateBox.value.value }
    var tlsContext: NIOSSLContext? { runtime.value.identity?.context }
    var isPaused: Bool { runtime.value.paused }

    func nextID() -> UInt64 {
        counter.withLock { value in
            value += 1
            return value
        }
    }

    /// Delivered in order on one serial queue.
    func emit(_ event: HostEvent) {
        eventQueue.async { [weak self] in self?.delegate?.event(event) }
    }

    func shouldStop(_ session: SessionHandle) -> Bool { isPaused || !session.isConnected }

    func features(secure: Bool) -> Features {
        let config = self.config
        return Features(voice: config.voiceAvailable, shell: config.allowShell, secure: secure, permission: input.isTrusted)
    }

    func broadcast(_ message: ServerMessage) async {
        for session in await sessions.all { session.writer.send(message) }
    }

    func broadcastFeatures() async {
        for session in await sessions.all { session.writer.send(.features(features(secure: session.secure))) }
    }

    /// SPEC §14.3.
    func settingsList(excluding deviceID: String) async -> [SettingsListItem] {
        let stamps = await settings.timestamps
        return await trust.entries.compactMap { entry -> SettingsListItem? in
            guard entry.id != deviceID, let updatedAt = stamps[entry.id] else { return nil }
            return SettingsListItem(
                id: entry.id, name: TextClean.presented(entry.name), model: entry.model, updatedAt: updatedAt)
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: WebSocket sessions

    /// Called on the channel's event loop right after the 101 response.
    func installSession(on channel: Channel, peer: PeerInfo) throws {
        let (events, control) = AsyncStream.makeStream(of: SessionEvent.self)
        let flow = InboundFlow(channel: channel)
        // Fragments are joined in the bridge, against a limit that grows after `welcome`.
        try channel.pipeline.syncOperations.addHandler(WebSocketBridge(events: control, flow: flow))
        Task {
            let runner = SessionRunner(
                core: self, channel: channel, peer: peer, events: events, control: control, flow: flow)
            await runner.run()
        }
    }

    // MARK: HTTP routes (SPEC §4.7)

    func route(path: String, query: String, headers: HTTPHeadersSnapshot, identity: ClientIdentity) async -> HTTPReply {
        let config = self.config
        switch path {
        case "/api/info":
            let body = JSON.obj([
                ("name", .string(config.computerName)), ("protocol", .int(1)), ("secure", .bool(identity.secure)),
                ("version", .string(config.appVersion)),
            ]).compact
            return HTTPReply(
                status: 200, contentType: "application/json", body: Array(body.utf8),
                extraHeaders: [("Cache-Control", "no-store")])
        case "/api/icon":
            return await icon(query: query)
        case "/remoto.crt":
            guard let identity = runtime.value.identity else { return .text(404, "No certificate yet.") }
            return HTTPReply(
                status: 200, contentType: "application/x-x509-ca-cert", body: identity.caDER,
                extraHeaders: [("Content-Disposition", "attachment; filename=\"Remoto.crt\"")])
        default:
            let webRoot = config.webRoot
            let inm = headers.ifNoneMatch
            return await Blocking.run { StaticFiles.reply(path: path, ifNoneMatch: inm, webRoot: webRoot) }
        }
    }

    private func icon(query: String) async -> HTTPReply {
        let items = HTTPRules.queryItems(query)
        guard let key = items["k"], await sessions.hasSessionKey(key) else { return .text(403, "Forbidden.") }
        guard let id = items["id"], (1...512).contains(id.utf8.count) else { return .text(400, "Bad icon id.") }
        let bucket = HTTPRules.iconBucket(items["size"])
        let cacheKey = "\(bucket):\(id)"
        let png: Data?
        if let cached = icons.withLock({ $0[cacheKey] }) {
            png = cached
        } else {
            let delegate = self.delegate
            png = await Blocking.run { delegate?.appIcon(id: id, sizePx: bucket) }
            if let png { icons.withLock { $0[cacheKey] = png } }
        }
        guard let png else { return .text(404, "No icon.") }
        return HTTPReply(
            status: 200, contentType: "image/png", body: [UInt8](png),
            extraHeaders: [("Cache-Control", "private, max-age=86400")])
    }
}

/// The request headers a route needs, copied out of NIO's types.
struct HTTPHeadersSnapshot: Sendable {
    var ifNoneMatch: String?
}
