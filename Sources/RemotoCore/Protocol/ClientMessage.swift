/// Authentication in `hello.auth` (SPEC §9.1).
enum HelloAuth: Equatable, Sendable {
    case token(String)
    case pair(String)
    case pin(String)
    case approve

    var methodName: String {
        switch self {
        case .token: "token"
        case .pair: "pair"
        case .pin: "pin"
        case .approve: "approve"
        }
    }
}

struct Hello: Equatable, Sendable {
    var v: UInt32
    var deviceID: String
    var name: String
    var model: String
    var auth: HelloAuth
    var remember: Bool
}

enum TextMode: String, Sendable {
    case unicode, keystrokes, paste
}

/// A JSON message from the phone (SPEC §9.1).
enum ClientMessage: Equatable, Sendable {
    case hello(Hello)
    case ping(id: JSON)
    case key(code: UInt16, down: Bool, mods: UInt16, repeats: Bool)
    case tap(code: UInt16, mods: UInt16)
    case button(MouseButton, PressOp)
    case media(MediaKey, PressOp)
    case volume(value: Float?, muted: Bool?)
    case text(String, mode: TextMode)
    case edit(delete: UInt32, insert: String)
    case release
    case action(Action, id: JSON?)
    case apps
    case appAction(id: String, op: AppOp)
    /// The raw deck, validated by the session so errors become a `deck` notice.
    case deckSave(JSON)
    case voiceStart(locale: String?)
    case voiceStop(cancel: Bool)
    case clipboardSet(String)
    case clipboardGet
    case settingsSave(settings: JSON, updatedAt: UInt64)
    case settingsList
    case settingsCopy(from: String)
}

struct ProtocolError: Error, Equatable, Sendable {
    var reason: String
    init(_ reason: String) { self.reason = reason }
}

extension ClientMessage {
    static func decode(_ text: String) throws(ProtocolError) -> ClientMessage {
        let json: JSON
        do { json = try JSON.parse(text) } catch { throw ProtocolError("invalid JSON") }
        return try decode(json)
    }

    static func decode(_ json: JSON) throws(ProtocolError) -> ClientMessage {
        guard json.isObject, let t = json["t"]?.stringValue else { throw ProtocolError("missing t") }
        let r = Reader(json: json, t: t)
        switch t {
        case "hello":
            guard let device = json["device"], device.isObject, let id = device["id"]?.stringValue else {
                throw ProtocolError("hello needs device.id")
            }
            return .hello(
                Hello(
                    v: try r.required("v") { $0.unsigned(UInt32.self) },
                    deviceID: id,
                    name: (try Reader(json: device, t: t).optional("name") { $0.stringValue }) ?? "",
                    model: (try Reader(json: device, t: t).optional("model") { $0.stringValue }) ?? "",
                    auth: try decodeAuth(json["auth"]),
                    remember: try r.optional("remember") { $0.boolValue } ?? false))
        case "ping":
            return .ping(id: json["id"] ?? .null)
        case "key":
            return .key(
                code: try r.required("code") { $0.unsigned(UInt16.self) },
                down: try r.required("down") { $0.boolValue },
                mods: try r.optional("mods") { $0.unsigned(UInt16.self) } ?? 0,
                repeats: try r.optional("repeat") { $0.boolValue } ?? false)
        case "tap":
            return .tap(
                code: try r.required("code") { $0.unsigned(UInt16.self) },
                mods: try r.optional("mods") { $0.unsigned(UInt16.self) } ?? 0)
        case "button":
            _ = try r.optional("mods") { $0.unsigned(UInt16.self) }
            return .button(
                try r.required("button") { $0.stringValue.flatMap(MouseButton.init(rawValue:)) },
                try r.required("op") { $0.stringValue.flatMap(PressOp.init(rawValue:)) })
        case "media":
            return .media(
                try r.required("key") { $0.stringValue.flatMap(MediaKey.init(rawValue:)) },
                try r.optional("op") { $0.stringValue.flatMap(PressOp.init(rawValue:)) } ?? .click)
        case "volume":
            let value = try r.optional("value") { $0.doubleValue }
            return .volume(value: value.map(Float.init), muted: try r.optional("muted") { $0.boolValue })
        case "text":
            return .text(
                try r.required("text") { $0.stringValue },
                mode: try r.optional("mode") { $0.stringValue.flatMap(TextMode.init(rawValue:)) } ?? .unicode)
        case "edit":
            return .edit(
                delete: try r.optional("delete") { $0.unsigned(UInt32.self) } ?? 0,
                insert: try r.optional("insert") { $0.stringValue } ?? "")
        case "release":
            return .release
        case "action":
            guard let raw = json["action"] else { throw ProtocolError("action needs action") }
            let action: Action
            do { action = try Action(json: raw) } catch { throw ProtocolError(error.message) }
            let id = json["id"].flatMap { $0 == .null ? nil : $0 }
            return .action(action, id: id)
        case "apps":
            return .apps
        case "appAction":
            return .appAction(
                id: try r.required("id") { $0.stringValue },
                op: try r.optional("op") { $0.stringValue.flatMap(AppOp.init(rawValue:)) } ?? .toggle)
        case "deckSave":
            guard let deck = json["deck"] else { throw ProtocolError("deckSave needs deck") }
            return .deckSave(deck)
        case "voiceStart":
            return .voiceStart(locale: try r.optional("locale") { $0.stringValue })
        case "voiceStop":
            return .voiceStop(cancel: try r.optional("cancel") { $0.boolValue } ?? false)
        case "clipboardSet":
            return .clipboardSet(try r.required("text") { $0.stringValue })
        case "clipboardGet":
            return .clipboardGet
        case "settingsSave":
            guard let settings = json["settings"] else { throw ProtocolError("settingsSave needs settings") }
            return .settingsSave(settings: settings, updatedAt: try r.required("updatedAt") { $0.unsigned(UInt64.self) })
        case "settingsList":
            return .settingsList
        case "settingsCopy":
            return .settingsCopy(from: try r.required("from") { $0.stringValue })
        default:
            throw ProtocolError("unknown message \(t)")
        }
    }

    private static func decodeAuth(_ json: JSON?) throws(ProtocolError) -> HelloAuth {
        guard let json, json.isObject, let method = json["method"]?.stringValue else {
            throw ProtocolError("hello needs auth.method")
        }
        switch method {
        case "token":
            guard let token = json["token"]?.stringValue else { throw ProtocolError("auth token needs token") }
            return .token(token)
        case "pair":
            guard let code = json["code"]?.stringValue else { throw ProtocolError("auth pair needs code") }
            return .pair(code)
        case "pin":
            guard let pin = json["pin"]?.stringValue else { throw ProtocolError("auth pin needs pin") }
            return .pin(pin)
        case "approve":
            return .approve
        default:
            throw ProtocolError("unknown auth method")
        }
    }

    /// Reads typed fields; a field that is present with the wrong type is an error,
    /// an absent (or null) optional field takes its default.
    private struct Reader {
        let json: JSON
        let t: String

        func required<T>(_ key: String, _ read: (JSON) -> T?) throws(ProtocolError) -> T {
            guard let value = json[key], let parsed = read(value) else { throw ProtocolError("\(t).\(key) is invalid") }
            return parsed
        }

        func optional<T>(_ key: String, _ read: (JSON) -> T?) throws(ProtocolError) -> T? {
            guard let value = json[key], value != .null else { return nil }
            guard let parsed = read(value) else { throw ProtocolError("\(t).\(key) is invalid") }
            return parsed
        }
    }
}
