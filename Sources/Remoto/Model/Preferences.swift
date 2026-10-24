import Foundation
import Observation
import RemotoCore

/// Which address the pairing QR points at.
enum LinkHostMode: String, CaseIterable, Identifiable, Sendable {
    case hostName, ipAddress, custom
    var id: String { rawValue }
}

/// Log levels understood by `RemotoHost.initLogging`.
enum LogLevel: String, CaseIterable, Identifiable, Sendable {
    case error, warning, info, debug
    var id: String { rawValue }
}

/// User preferences, stored in `UserDefaults` (SPEC §15.9 defaults).
@MainActor
@Observable
final class Preferences {
    static let defaultPort = 8740

    private enum Key {
        static let port = "port"
        static let linkHostMode = "linkHostMode"
        static let customHost = "customHost"
        static let allowPin = "allowPin"
        static let allowApproval = "allowApproval"
        static let allowShell = "allowShell"
        static let allowLocalProxy = "allowLocalProxy"
        static let voiceEnabled = "voiceEnabled"
        static let welcomeDone = "welcomeDone"
        static let appFolders = "appFolders"
        static let logFilter = "logFilter"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var port: Int { didSet { defaults.set(port, forKey: Key.port) } }
    var linkHostMode: LinkHostMode { didSet { defaults.set(linkHostMode.rawValue, forKey: Key.linkHostMode) } }
    var customHost: String { didSet { defaults.set(customHost, forKey: Key.customHost) } }
    var allowPin: Bool { didSet { defaults.set(allowPin, forKey: Key.allowPin) } }
    var allowApproval: Bool { didSet { defaults.set(allowApproval, forKey: Key.allowApproval) } }
    var allowShell: Bool { didSet { defaults.set(allowShell, forKey: Key.allowShell) } }
    var allowLocalProxy: Bool { didSet { defaults.set(allowLocalProxy, forKey: Key.allowLocalProxy) } }
    var voiceEnabled: Bool { didSet { defaults.set(voiceEnabled, forKey: Key.voiceEnabled) } }
    var welcomeDone: Bool { didSet { defaults.set(welcomeDone, forKey: Key.welcomeDone) } }
    var appFolders: [String] { didSet { defaults.set(appFolders, forKey: Key.appFolders) } }
    var logFilter: LogLevel { didSet { defaults.set(logFilter.rawValue, forKey: Key.logFilter) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.port: Self.defaultPort,
            Key.linkHostMode: LinkHostMode.hostName.rawValue,
            Key.customHost: "",
            Key.allowPin: true,
            Key.allowApproval: true,
            Key.allowShell: false,
            Key.allowLocalProxy: false,
            Key.voiceEnabled: true,
            Key.welcomeDone: false,
            Key.appFolders: [String](),
            Key.logFilter: LogLevel.info.rawValue,
        ])
        let storedPort = defaults.integer(forKey: Key.port)
        port = Self.isValidPort(storedPort) ? storedPort : Self.defaultPort
        linkHostMode = LinkHostMode(rawValue: defaults.string(forKey: Key.linkHostMode) ?? "") ?? .hostName
        customHost = defaults.string(forKey: Key.customHost) ?? ""
        allowPin = defaults.bool(forKey: Key.allowPin)
        allowApproval = defaults.bool(forKey: Key.allowApproval)
        allowShell = defaults.bool(forKey: Key.allowShell)
        allowLocalProxy = defaults.bool(forKey: Key.allowLocalProxy)
        voiceEnabled = defaults.bool(forKey: Key.voiceEnabled)
        welcomeDone = defaults.bool(forKey: Key.welcomeDone)
        appFolders = defaults.stringArray(forKey: Key.appFolders) ?? []
        logFilter = LogLevel(rawValue: defaults.string(forKey: Key.logFilter) ?? "") ?? .info
    }

    /// The UI accepts 1024–65535.
    static func isValidPort(_ port: Int) -> Bool { (1024...65535).contains(port) }

    var linkHost: LinkHost {
        switch linkHostMode {
        case .hostName: .hostName
        case .ipAddress: .ipAddress
        case .custom:
            customHost.trimmingCharacters(in: .whitespaces).isEmpty
                ? .hostName : .custom(customHost.trimmingCharacters(in: .whitespaces))
        }
    }
}
