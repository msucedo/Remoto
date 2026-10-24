/// System shortcuts a tile can trigger (SPEC §13.3).
enum SystemAction: String, Sendable, CaseIterable {
    case missionControl, appExpose, showDesktop, launchpad, spotlight, spaceLeft, spaceRight, appSwitcher
    case lockScreen, sleepDisplay, sleep, screenshot, screenshotArea, screenshotTool, forceQuit, emojiPicker
    case closeWindow, quitApp, minimize, undo, redo, copy, cut, paste, selectAll, find, newTab, closeTab
    case nextTab, previousTab, back, forward, reload, zoomIn, zoomOut, actualSize, fullscreen, hideApp
}

/// A deck action (SPEC §12.3).
indirect enum Action: Sendable, Equatable {
    case keys(code: UInt16, mods: UInt16, char: String?)
    case text(String, enter: Bool)
    case media(MediaKey)
    case app(id: String, op: AppOp)
    case url(String)
    case system(SystemAction)
    case shortcut(String)
    case shell(String)
    case mouse(MouseButton, clicks: UInt8)
    case delay(ms: UInt32)
    case sequence([Action])
}

struct ActionError: Error, Equatable, Sendable {
    var message: String
    init(_ message: String) { self.message = message }
}

extension Action {
    static let maxDepth = 2
    static let maxSteps = 64

    // MARK: Decoding

    init(json: JSON) throws(ActionError) {
        guard json.isObject, let kind = json["kind"]?.stringValue else { throw ActionError("Action needs a kind.") }
        func string(_ key: String) throws(ActionError) -> String {
            guard let s = json[key]?.stringValue else { throw ActionError("Action \(kind) needs \(key).") }
            return s
        }
        func optional<T>(_ key: String, _ read: (JSON) -> T?) throws(ActionError) -> T? {
            guard let value = json[key], value != .null else { return nil }
            guard let parsed = read(value) else { throw ActionError("Action \(kind) has an invalid \(key).") }
            return parsed
        }
        switch kind {
        case "keys":
            guard let code = try optional("code", { $0.unsigned(UInt16.self) }) else {
                throw ActionError("Action keys needs code.")
            }
            self = .keys(
                code: code, mods: try optional("mods", { $0.unsigned(UInt16.self) }) ?? 0,
                char: try optional("char", \.stringValue))
        case "text":
            self = .text(try string("text"), enter: try optional("enter", \.boolValue) ?? false)
        case "media":
            guard let key = MediaKey(rawValue: try string("key")) else { throw ActionError("Unknown media key.") }
            self = .media(key)
        case "app":
            let op = try optional("op", { $0.stringValue.flatMap(AppOp.init(rawValue:)) }) ?? .toggle
            self = .app(id: try string("id"), op: op)
        case "url":
            self = .url(try string("url"))
        case "system":
            guard let name = SystemAction(rawValue: try string("name")) else {
                throw ActionError("Unknown system action.")
            }
            self = .system(name)
        case "shortcut":
            self = .shortcut(try string("name"))
        case "shell":
            self = .shell(try string("command"))
        case "mouse":
            guard let button = MouseButton(rawValue: try string("button")) else {
                throw ActionError("Unknown mouse button.")
            }
            self = .mouse(button, clicks: try optional("clicks", { $0.unsigned(UInt8.self) }) ?? 1)
        case "delay":
            guard let ms = try optional("ms", { $0.unsigned(UInt32.self) }) else {
                throw ActionError("Action delay needs ms.")
            }
            self = .delay(ms: ms)
        case "sequence":
            guard let steps = json["steps"]?.arrayValue else { throw ActionError("Action sequence needs steps.") }
            var parsed: [Action] = []
            for step in steps { parsed.append(try Action(json: step)) }
            self = .sequence(parsed)
        default:
            throw ActionError("Unknown action kind.")
        }
    }

    // MARK: Encoding

    var json: JSON {
        switch self {
        case .keys(let code, let mods, let char):
            .obj([("kind", .string("keys")), ("code", .int(code)), ("mods", .int(mods)), ("char", char.map(JSON.string))])
        case .text(let text, let enter):
            .obj([("kind", .string("text")), ("text", .string(text)), ("enter", .bool(enter))])
        case .media(let key):
            .obj([("kind", .string("media")), ("key", .string(key.rawValue))])
        case .app(let id, let op):
            .obj([("kind", .string("app")), ("id", .string(id)), ("op", .string(op.rawValue))])
        case .url(let url):
            .obj([("kind", .string("url")), ("url", .string(url))])
        case .system(let name):
            .obj([("kind", .string("system")), ("name", .string(name.rawValue))])
        case .shortcut(let name):
            .obj([("kind", .string("shortcut")), ("name", .string(name))])
        case .shell(let command):
            .obj([("kind", .string("shell")), ("command", .string(command))])
        case .mouse(let button, let clicks):
            .obj([("kind", .string("mouse")), ("button", .string(button.rawValue)), ("clicks", .int(clicks))])
        case .delay(let ms):
            .obj([("kind", .string("delay")), ("ms", .int(ms))])
        case .sequence(let steps):
            .obj([("kind", .string("sequence")), ("steps", .array(steps.map(\.json)))])
        }
    }

    // MARK: Validation (SPEC §12.3)

    func validate(depth: Int = 0) throws(ActionError) {
        switch self {
        case .keys(let code, let mods, let char):
            guard code <= 0xFF, mods < 0x20, (char?.utf8.count ?? 0) <= 16 else { throw ActionError("Invalid key.") }
        case .text(let text, _):
            guard text.utf8.count <= 4096 else { throw ActionError("The text is too long.") }
        case .media:
            break
        case .app(let id, _):
            guard (1...512).contains(id.utf8.count) else { throw ActionError("Invalid app id.") }
        case .url(let url):
            guard url.utf8.count <= 4096, url.contains(":") else { throw ActionError("Invalid link.") }
        case .system:
            break
        case .shortcut(let name):
            guard (1...512).contains(name.utf8.count) else { throw ActionError("Invalid shortcut name.") }
        case .shell(let command):
            guard command.utf8.count <= 4096 else { throw ActionError("The command is too long.") }
        case .mouse(_, let clicks):
            guard (1...3).contains(clicks) else { throw ActionError("Clicks must be 1 to 3.") }
        case .delay(let ms):
            guard ms <= 10_000 else { throw ActionError("A delay can be at most 10 seconds.") }
        case .sequence(let steps):
            guard depth <= Self.maxDepth else { throw ActionError("Sequences are nested too deep.") }
            guard steps.count <= Self.maxSteps else { throw ActionError("A sequence can have at most 64 steps.") }
            for step in steps { try step.validate(depth: depth + 1) }
        }
    }
}
