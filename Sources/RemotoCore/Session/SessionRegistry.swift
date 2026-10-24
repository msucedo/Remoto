import Foundation

struct PeerInfo: Sendable, Equatable {
    var ip: String
    var secure: Bool
}

/// A connected, authenticated phone. Shared between the session loop, the
/// action worker and host-wide broadcasts.
final class SessionHandle: Sendable {
    let id: UInt64
    let deviceID: String
    let name: String
    let model: String
    let address: String
    let connectedAt: Int64
    let secure: Bool
    let remembered: Bool
    let sessionKey: String
    let writer: FrameWriter
    private let events: AsyncStream<SessionEvent>.Continuation
    private let connectedFlag = Locked(true)

    init(
        id: UInt64, deviceID: String, name: String, model: String, peer: PeerInfo, remembered: Bool,
        sessionKey: String, writer: FrameWriter, events: AsyncStream<SessionEvent>.Continuation
    ) {
        self.id = id
        self.deviceID = deviceID
        self.name = name
        self.model = model
        self.address = peer.ip
        self.connectedAt = Unix.now()
        self.secure = peer.secure
        self.remembered = remembered
        self.sessionKey = sessionKey
        self.writer = writer
        self.events = events
    }

    var isConnected: Bool { connectedFlag.value }
    func markDisconnected() { connectedFlag.set(false) }

    /// Queues an event on the session's own loop.
    func post(_ event: SessionEvent) { events.yield(event) }

    var device: ConnectedDevice {
        ConnectedDevice(
            session: id, deviceId: deviceID, name: name, model: model, address: address, connectedAt: connectedAt,
            secure: secure, remembered: remembered)
    }
}

actor SessionRegistry {
    private var byID: [UInt64: SessionHandle] = [:]

    func add(_ handle: SessionHandle) { byID[handle.id] = handle }

    @discardableResult
    func remove(_ id: UInt64) -> SessionHandle? { byID.removeValue(forKey: id) }

    func get(_ id: UInt64) -> SessionHandle? { byID[id] }

    var all: [SessionHandle] {
        byID.values.sorted { ($0.connectedAt, $0.id) < ($1.connectedAt, $1.id) }
    }

    func remembered(deviceID: String?) -> [SessionHandle] {
        byID.values.filter { $0.remembered && (deviceID == nil || $0.deviceID == deviceID) }
    }

    /// Whether `key` is the `sessionKey` of a live session (constant-time per key).
    func hasSessionKey(_ key: String) -> Bool {
        var found = false
        for handle in byID.values where Secrets.constantTimeEquals(key, handle.sessionKey) { found = true }
        return found
    }

    var isEmpty: Bool { byID.isEmpty }
}
