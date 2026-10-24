// Public types shared by the input engine and the core. The raw values are the
// protocol spelling, so the core can encode and decode them directly.

public enum MouseButton: String, Codable, Sendable, CaseIterable {
    case left, right, middle, back, forward

    /// CGMouseButton number.
    public var number: Int64 {
        switch self {
        case .left: 0
        case .right: 1
        case .middle: 2
        case .back: 3
        case .forward: 4
        }
    }
}

public enum PressOp: String, Codable, Sendable {
    case click, down, up
}

public enum MediaKey: String, Codable, Sendable, CaseIterable {
    case volumeUp, volumeDown, mute, brightnessUp, brightnessDown, playPause, next, previous,
        fastForward, rewind, illuminationUp, illuminationDown, illuminationToggle
}

public struct KeyCap: Codable, Sendable, Equatable {
    public var code: UInt16
    public var base: String
    public var shift: String
    public var option: String
    public var optionShift: String
    /// bit0 base, bit1 shift, bit2 option, bit3 optionShift.
    public var dead: UInt8

    public init(code: UInt16, base: String, shift: String, option: String, optionShift: String, dead: UInt8) {
        self.code = code
        self.base = base
        self.shift = shift
        self.option = option
        self.optionShift = optionShift
        self.dead = dead
    }
}

public struct KeyboardLayout: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var iso: Bool
    public var keys: [KeyCap]

    public init(id: String, name: String, iso: Bool, keys: [KeyCap]) {
        self.id = id
        self.name = name
        self.iso = iso
        self.keys = keys
    }
}

/// System keyboard and mouse timing. Out-of-range values are clamped by the engine.
public struct InputTiming: Sendable, Equatable {
    public var repeatDelayMs: UInt32
    public var repeatIntervalMs: UInt32
    public var doubleClickMs: UInt32

    public init(repeatDelayMs: UInt32 = 500, repeatIntervalMs: UInt32 = 83, doubleClickMs: UInt32 = 500) {
        self.repeatDelayMs = repeatDelayMs
        self.repeatIntervalMs = repeatIntervalMs
        self.doubleClickMs = doubleClickMs
    }
}

/// One thing a phone asked the Mac to do with its pointer or keyboard.
public enum Input: Sendable, Equatable {
    case move(dx: Double, dy: Double)
    /// `phase`: 0 wheel, 1 began, 2 changed, 4 ended, 8 cancelled.
    case scroll(phase: UInt8, dx: Double, dy: Double)
    case fling(vx: Double, vy: Double)
    /// A finger touched the surface: stops inertia.
    case touch
    case key(code: UInt16, down: Bool, mods: UInt16, repeats: Bool)
    case tap(code: UInt16, mods: UInt16)
    /// A shortcut on a letter, resolved through the active layout (falls back to `code`).
    case tapChar(code: UInt16, mods: UInt16, char: Character)
    case button(MouseButton, PressOp)
    /// 1 to 3 clicks.
    case click(MouseButton, count: Int)
    case media(MediaKey, PressOp)
    case text(String, keystrokes: Bool)
    case edit(delete: Int, insert: String)
    /// Let go of everything the session is holding.
    case release
}

/// Something the phone should be told about, rate limited per kind and session.
public enum InputNotice: Sendable, Hashable {
    case accessibility
    case secureInput
}
