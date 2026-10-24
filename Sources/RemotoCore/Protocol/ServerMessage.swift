/// Why a `hello` was refused (SPEC §9.4).
enum DenyReason: String, Sendable {
    case unknown, wrongPin, pinClosed, expiredCode, rejected, blocked, busy, incompatible
}

enum NoticeLevel: String, Sendable {
    case info, warning, error
}

/// Short `notice` codes (SPEC §9.4).
enum NoticeCode: String, Sendable {
    case permission, secureInput, tooLong, busy, paused, deck, settings
}

struct Features: Equatable, Sendable {
    var voice: Bool
    var shell: Bool
    var secure: Bool
    var permission: Bool

    var json: JSON {
        .obj([("voice", .bool(voice)), ("shell", .bool(shell)), ("secure", .bool(secure)), ("permission", .bool(permission))])
    }
}

struct SettingsListItem: Equatable, Sendable {
    var id: String
    var name: String
    var model: String
    var updatedAt: UInt64
}

/// Everything `welcome` carries (SPEC §8.2).
struct Welcome: Sendable {
    var hostName: String
    var hostVersion: String
    var sessionKey: String
    var token: String?
    var features: Features
    var deck: Deck
    var layout: KeyboardLayout?
    var volume: VolumeState?
    var paused: Bool
    var settings: StoredSettings?
}

struct VolumeState: Equatable, Sendable {
    var value: Float
    var muted: Bool
}

/// A JSON message to the phone (SPEC §9.3). `json` writes fields in the
/// normative order.
enum ServerMessage: Sendable {
    case welcome(Welcome)
    case pending
    case denied(DenyReason, retryAfter: UInt32?)
    case pong(id: JSON)
    case apps([AppEntry])
    case appsChanged
    case deck(Deck)
    case layout(KeyboardLayout)
    case volume(VolumeState)
    case volumeUnavailable
    case paused(Bool)
    case features(Features)
    case notice(NoticeLevel, code: NoticeCode?, message: String)
    case actionResult(id: JSON?, ok: Bool, message: String?)
    case clipboard(String?)
    case bye(reason: String, reconnect: Bool)
    case voice(VoiceUpdate)
    case settings(StoredSettings)
    case settingsList([SettingsListItem])

    var json: JSON {
        switch self {
        case .welcome(let w):
            return .obj([
                ("t", .string("welcome")),
                ("v", .int(1)),
                ("host", .obj([("name", .string(w.hostName)), ("version", .string(w.hostVersion)), ("os", .string("macOS"))])),
                ("sessionKey", .string(w.sessionKey)),
                ("token", .optString(w.token)),
                ("features", w.features.json),
                ("deck", w.deck.json),
                ("layout", w.layout.map(Self.layoutJSON)),
                ("volume", w.volume.map(Self.volumeJSON)),
                ("paused", .bool(w.paused)),
                ("settings", w.settings?.wire),
            ])
        case .pending:
            return .obj([("t", .string("pending"))])
        case .denied(let reason, let retryAfter):
            return .obj([
                ("t", .string("denied")), ("reason", .string(reason.rawValue)),
                ("retryAfter", retryAfter.map { .int(max(1, $0)) }),
            ])
        case .pong(let id):
            return .obj([("t", .string("pong")), ("id", id)])
        case .apps(let apps):
            return .obj([("t", .string("apps")), ("apps", .array(apps.map(Self.appJSON)))])
        case .appsChanged:
            return .obj([("t", .string("appsChanged"))])
        case .deck(let deck):
            return .obj([("t", .string("deck")), ("deck", deck.json)])
        case .layout(let layout):
            return .obj([("t", .string("layout")), ("layout", Self.layoutJSON(layout))])
        case .volume(let v):
            return .obj([("t", .string("volume")), ("value", .float(v.value)), ("muted", .bool(v.muted))])
        case .volumeUnavailable:
            return .obj([("t", .string("volumeUnavailable"))])
        case .paused(let paused):
            return .obj([("t", .string("paused")), ("paused", .bool(paused))])
        case .features(let features):
            return .obj([("t", .string("features")), ("features", features.json)])
        case .notice(let level, let code, let message):
            return .obj([
                ("t", .string("notice")), ("level", .string(level.rawValue)), ("code", code.map { .string($0.rawValue) }),
                ("message", .string(message)),
            ])
        case .actionResult(let id, let ok, let message):
            return .obj([("t", .string("actionResult")), ("id", id), ("ok", .bool(ok)), ("message", message.map(JSON.string))])
        case .clipboard(let text):
            return .obj([("t", .string("clipboard")), ("text", .optString(text))])
        case .bye(let reason, let reconnect):
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            return .obj([
                ("t", .string("bye")), ("reason", .string(trimmed.isEmpty ? "Disconnected." : reason)),
                ("reconnect", .bool(reconnect)),
            ])
        case .voice(let update):
            return .obj([
                ("t", .string("voice")), ("state", .string(update.state.rawValue)), ("text", update.text.map(JSON.string)),
                ("final", .bool(update.isFinal)), ("message", update.message.map(JSON.string)),
            ])
        case .settings(let stored):
            return .obj([("t", .string("settings")), ("settings", stored.settings), ("updatedAt", .int(stored.updatedAt))])
        case .settingsList(let items):
            return .obj([
                ("t", .string("settingsList")),
                ("devices", .array(items.map {
                    .obj([("id", .string($0.id)), ("name", .string($0.name)), ("model", .string($0.model)), ("updatedAt", .int($0.updatedAt))])
                })),
            ])
        }
    }

    static func appJSON(_ app: AppEntry) -> JSON {
        .obj([
            ("id", .string(app.id)), ("name", .string(app.name)), ("running", .bool(app.running)),
            ("active", .bool(app.active)), ("hidden", .bool(app.hidden)),
        ])
    }

    static func volumeJSON(_ v: VolumeState) -> JSON {
        .obj([("value", .float(v.value)), ("muted", .bool(v.muted))])
    }

    static func layoutJSON(_ layout: KeyboardLayout) -> JSON {
        .obj([
            ("id", .string(layout.id)), ("name", .string(layout.name)), ("iso", .bool(layout.iso)),
            ("keys", .array(layout.keys.map {
                .obj([
                    ("code", .int($0.code)), ("base", .string($0.base)), ("shift", .string($0.shift)),
                    ("option", .string($0.option)), ("optionShift", .string($0.optionShift)), ("dead", .int($0.dead)),
                ])
            })),
        ])
    }
}

import Foundation
