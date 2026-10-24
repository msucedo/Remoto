import Foundation
@_exported import RemotoInput

/// Which host the pairing link (QR) points at (SPEC §3.2).
public enum LinkHost: Sendable, Equatable {
    /// The Mac's `.local` name.
    case hostName
    /// The first LAN IPv4 address.
    case ipAddress
    /// A user-provided address, optionally with `http://`/`https://` and a port.
    case custom(String)
}

/// Everything the app tells the core (SPEC §2.2).
public struct HostConfig: Sendable, Equatable {
    /// Preferred port; 0 picks an ephemeral one. The app's default is 8740.
    public var port: UInt16
    /// Persistence folder (`~/Library/Application Support/Remoto`).
    public var dataDir: URL
    /// The web client folder, or nil when it isn't bundled.
    public var webRoot: URL?
    /// The Mac's mDNS name, e.g. `Studio.local`.
    public var hostName: String
    /// The visible computer name.
    public var computerName: String
    public var appVersion: String
    public var linkHost: LinkHost
    /// Trust `X-Forwarded-*` from loopback peers.
    public var allowLocalProxy: Bool
    public var allowPin: Bool
    public var allowApproval: Bool
    /// Allow `shell` deck actions and `file:` URLs.
    public var allowShell: Bool
    /// Dictation enabled (user setting and speech permission not denied).
    public var voiceAvailable: Bool

    public init(
        port: UInt16 = 8740,
        dataDir: URL,
        webRoot: URL? = nil,
        hostName: String = "",
        computerName: String = "Mac",
        appVersion: String = "0.0.0",
        linkHost: LinkHost = .hostName,
        allowLocalProxy: Bool = false,
        allowPin: Bool = true,
        allowApproval: Bool = true,
        allowShell: Bool = false,
        voiceAvailable: Bool = true
    ) {
        self.port = port
        self.dataDir = dataDir
        self.webRoot = webRoot
        self.hostName = hostName
        self.computerName = computerName
        self.appVersion = appVersion
        self.linkHost = linkHost
        self.allowLocalProxy = allowLocalProxy
        self.allowPin = allowPin
        self.allowApproval = allowApproval
        self.allowShell = allowShell
        self.voiceAvailable = voiceAvailable
    }
}

public struct PairingInfo: Sendable, Equatable {
    /// `http://<host>:<port>/#pair=<code>`, the QR content.
    public var link: String
    public var address: String
    public var secureAddress: String
    public var pin: String
    public var expiresInSecs: UInt32
    public var port: UInt16
    public var addresses: [String]
    public var vpnAddresses: [String]
    /// SHA-256 of the CA certificate, `AA:BB:…` (empty without a TLS identity).
    public var caFingerprint: String
}

public struct ConnectedDevice: Sendable, Equatable, Identifiable {
    public var session: UInt64
    public var deviceId: String
    public var name: String
    public var model: String
    public var address: String
    /// UNIX seconds.
    public var connectedAt: Int64
    public var secure: Bool
    public var remembered: Bool
    public var id: UInt64 { session }
}

public struct TrustedDevice: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var model: String
    public var pairedAt: Int64
    public var lastSeen: Int64
    public var lastAddress: String
}

/// `deviceName` and `model` come from the phone and can say anything; show
/// `address` separately and warn when `nameMatchesTrustedDevice` is true.
public struct ApprovalRequest: Sendable, Equatable, Identifiable {
    public var id: UInt64
    public var deviceName: String
    public var model: String
    public var address: String
    /// A trusted device already has this name (case-insensitive): possible impersonation.
    public var nameMatchesTrustedDevice: Bool

    public init(id: UInt64, deviceName: String, model: String, address: String, nameMatchesTrustedDevice: Bool = false) {
        self.id = id
        self.deviceName = deviceName
        self.model = model
        self.address = address
        self.nameMatchesTrustedDevice = nameMatchesTrustedDevice
    }
}

public struct AppEntry: Sendable, Equatable {
    /// Bundle id.
    public var id: String
    public var name: String
    public var running: Bool
    public var active: Bool
    public var hidden: Bool

    public init(id: String, name: String, running: Bool, active: Bool, hidden: Bool) {
        self.id = id
        self.name = name
        self.running = running
        self.active = active
        self.hidden = hidden
    }
}

public struct VoiceUpdate: Sendable, Equatable {
    public enum State: String, Sendable {
        case listening, stopped, unavailable, error
    }

    public var state: State
    public var text: String?
    public var isFinal: Bool
    public var message: String?

    public init(state: State, text: String? = nil, isFinal: Bool = false, message: String? = nil) {
        self.state = state
        self.text = text
        self.isFinal = isFinal
        self.message = message
    }
}

public enum AppOp: String, Sendable, CaseIterable {
    case open, toggle, hide, quit
}

public enum NativeCommand: String, Sendable, CaseIterable {
    case missionControl, launchpad, lockScreen, sleepDisplay, sleep
}

/// Notifications from the core to the app (SPEC §2.5).
public enum HostEvent: Sendable, Equatable {
    case started(port: UInt16, preferredPortTaken: Bool)
    case stopped
    case failed(String)
    case sessionsChanged
    case devicesChanged
    case pairingChanged
    case approvalRequested(ApprovalRequest)
    case approvalEnded(UInt64)
    /// A device finished pairing (by code, PIN or approval) with this name.
    case paired(String)
    /// Something the user should see, like missing Accessibility permission.
    case notice(String)
}

/// What the core asks of the app (SPEC §2.4). Every method is called off the
/// main thread, from a background thread that may block; hop to the main
/// actor yourself when you need it. Events arrive in order on one serial queue.
public protocol HostDelegate: AnyObject, Sendable {
    func event(_ event: HostEvent)
    func apps() -> [AppEntry]
    /// PNG of the app icon, `sizePx` square (64, 128, 256 or 512).
    func appIcon(id: String, sizePx: Int) -> Data?
    func performApp(id: String, op: AppOp) -> Bool
    func runNative(_ command: NativeCommand) -> Bool
    func openURL(_ url: String) -> Bool
    func runShortcut(name: String) -> Bool
    func readClipboard() -> String?
    func writeClipboard(_ text: String)
    /// Snapshot the clipboard and put `text` on it; return false if that failed.
    func pasteBegin(_ text: String) -> Bool
    /// Restore the snapshot if nobody changed the clipboard since `pasteBegin`.
    func pasteEnd()
    func setVolume(value: Float?, muted: Bool?)
    /// Start dictation for a session; report progress with `RemotoHost.voiceUpdate`.
    func voiceBegin(session: UInt64, locale: String?) -> Bool
    /// PCM Int16 little-endian, mono, 16 kHz. Calls for a session arrive in order.
    func voiceFeed(session: UInt64, pcm: Data)
    func voiceEnd(session: UInt64, cancel: Bool)
}

/// An error with a message meant for people.
public struct HostError: Error, Sendable, Equatable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}
