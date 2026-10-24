/// How each system action is carried out (SPEC §13.3).
enum SystemStep: Equatable, Sendable {
    /// `tap(code, mods)`.
    case tap(code: UInt16, mods: UInt16)
    /// A letter shortcut resolved through the layout; `code` is the ANSI fallback.
    case letter(Character, code: UInt16, mods: UInt16)
    /// Wait for the engine, then ask the app.
    case native(NativeCommand)
}

enum Mods {
    static let cmd: UInt16 = 0x0001
    static let shift: UInt16 = 0x0002
    static let option: UInt16 = 0x0004
    static let control: UInt16 = 0x0008
}

enum SystemActions {
    /// ANSI fallback keycodes for letters and named keys (SPEC Appendix B.2).
    static let ansi: [String: UInt16] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07, "c": 0x08,
        "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "1": 0x12,
        "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18, "9": 0x19, "7": 0x1A, "-": 0x1B,
        "8": 0x1C, "0": 0x1D, "]": 0x1E, "o": 0x1F, "u": 0x20, "[": 0x21, "i": 0x22, "p": 0x23, "l": 0x25,
        "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29, "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E,
        ".": 0x2F, "`": 0x32, "up": 0x7E, "down": 0x7D, "left": 0x7B, "right": 0x7C, "tab": 0x30,
        "space": 0x31, "return": 0x24, "delete": 0x33, "escape": 0x35, "f11": 0x67,
    ]

    static func letter(_ c: Character, _ mods: UInt16) -> SystemStep {
        .letter(c, code: ansi[String(c)] ?? 0, mods: mods)
    }

    static func step(for action: SystemAction) -> SystemStep {
        let cmd = Mods.cmd, shift = Mods.shift, opt = Mods.option, ctrl = Mods.control
        switch action {
        case .missionControl: return .native(.missionControl)
        case .appExpose: return .tap(code: 0x7D, mods: ctrl)
        case .showDesktop: return .tap(code: 0x67, mods: 0)
        case .launchpad: return .native(.launchpad)
        case .spotlight: return .tap(code: 0x31, mods: cmd)
        case .spaceLeft: return .tap(code: 0x7B, mods: ctrl)
        case .spaceRight: return .tap(code: 0x7C, mods: ctrl)
        case .appSwitcher: return .tap(code: 0x30, mods: cmd)
        case .lockScreen: return .native(.lockScreen)
        case .sleepDisplay: return .native(.sleepDisplay)
        case .sleep: return .native(.sleep)
        case .screenshot: return .tap(code: 0x14, mods: cmd | shift)
        case .screenshotArea: return .tap(code: 0x15, mods: cmd | shift)
        case .screenshotTool: return .tap(code: 0x17, mods: cmd | shift)
        case .forceQuit: return .tap(code: 0x35, mods: cmd | opt)
        case .emojiPicker: return .tap(code: 0x31, mods: ctrl | cmd)
        case .closeWindow: return letter("w", cmd)
        case .quitApp: return letter("q", cmd)
        case .minimize: return letter("m", cmd)
        case .undo: return letter("z", cmd)
        case .redo: return letter("z", cmd | shift)
        case .copy: return letter("c", cmd)
        case .cut: return letter("x", cmd)
        case .paste: return letter("v", cmd)
        case .selectAll: return letter("a", cmd)
        case .find: return letter("f", cmd)
        case .newTab: return letter("t", cmd)
        case .closeTab: return letter("w", cmd)
        case .nextTab: return .tap(code: 0x30, mods: ctrl)
        case .previousTab: return .tap(code: 0x30, mods: ctrl | shift)
        case .back: return .tap(code: 0x21, mods: cmd)
        case .forward: return .tap(code: 0x1E, mods: cmd)
        case .reload: return letter("r", cmd)
        case .zoomIn: return .tap(code: 0x18, mods: cmd)
        case .zoomOut: return .tap(code: 0x1B, mods: cmd)
        case .actualSize: return .tap(code: 0x1D, mods: cmd)
        case .fullscreen: return letter("f", ctrl | cmd)
        case .hideApp: return letter("h", cmd)
        }
    }
}
