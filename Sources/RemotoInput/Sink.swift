import CoreGraphics
import Foundation

// Where the engine's events go. The engine only builds `SinkEvent`s and asks
// the sink about the world (cursor, screens, permissions); `SystemSink` turns
// them into CGEvents and `LogSink` into lines of an `EventLog`.

enum MouseEventKind: String, Equatable {
    case moved, dragged, down, up
}

struct ScrollEvent: Equatable {
    /// `kCGScrollWheelEventScrollPhase`: 0, 1 began, 2 changed, 4 ended, 8 cancelled.
    var phase: UInt8
    /// `kCGScrollWheelEventMomentumPhase`: 0 none, 1 begin, 2 continue, 3 end.
    var momentum: UInt8
    /// Vertical wheel (axis 1), integer pixels.
    var wheel1: Int32
    /// Horizontal wheel (axis 2), integer pixels.
    var wheel2: Int32
    /// Unrounded deltas for the fixed-point fields.
    var dx: Double
    var dy: Double
    var x: Double
    var y: Double
    var flags: UInt64
}

enum SinkEvent: Equatable, CustomStringConvertible {
    case mouse(MouseEventKind, button: MouseButton, x: Double, y: Double, dx: Int64, dy: Int64, clickState: Int64, flags: UInt64)
    case key(code: UInt16, down: Bool, flags: UInt64, autorepeat: Bool, text: String?)
    case flagsChanged(code: UInt16, flags: UInt64)
    case scroll(ScrollEvent)
    case media(MediaKey, down: Bool)
    /// Only recorded by `LogSink` (the real toggle goes through IOHID).
    case capsLock(on: Bool)

    var description: String {
        switch self {
        case let .mouse(kind, button, x, y, dx, dy, clickState, flags):
            switch kind {
            case .moved:
                return "move \(dx),\(dy) at=\(fmt(x)),\(fmt(y)) flags=\(hex(flags))"
            case .dragged:
                return "drag \(button.rawValue) \(dx),\(dy) at=\(fmt(x)),\(fmt(y)) flags=\(hex(flags))"
            case .down, .up:
                let name = kind == .down ? "mouseDown" : "mouseUp"
                return "\(name) \(button.rawValue) click=\(clickState) at=\(fmt(x)),\(fmt(y)) flags=\(hex(flags))"
            }
        case let .key(code, down, flags, autorepeat, text):
            var line = "\(down ? "keyDown" : "keyUp") \(hex2(code)) flags=\(hex(flags))"
            if autorepeat { line += " repeat" }
            if let text { line += " text=\(text.debugDescription)" }
            return line
        case let .flagsChanged(code, flags):
            return "flagsChanged \(hex2(code)) flags=\(hex(flags))"
        case let .scroll(e):
            return "scroll phase=\(e.phase) momentum=\(e.momentum) dy=\(fmt(e.dy)) dx=\(fmt(e.dx)) wheel=\(e.wheel1),\(e.wheel2) at=\(fmt(e.x)),\(fmt(e.y)) flags=\(hex(e.flags))"
        case let .media(key, down):
            return "media \(key.rawValue) nx=\(key.nxKeyType) \(down ? "down" : "up")"
        case let .capsLock(on):
            return "capsLock \(on ? "on" : "off")"
        }
    }
}

private func hex(_ v: UInt64) -> String { "0x" + String(v, radix: 16) }

private func hex2(_ v: UInt16) -> String {
    let s = String(v, radix: 16)
    return "0x" + (s.count < 2 ? "0" + s : s)
}

/// Integers without decimals, the rest with up to 3.
func fmt(_ v: Double) -> String {
    if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
    var s = String(format: "%.3f", v)
    while s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    return s
}

protocol EventSink: AnyObject {
    func post(_ event: SinkEvent)
    /// Flips the real CapsLock lock state.
    func toggleCapsLock()
    func capsLockIsOn() -> Bool
    func cursorPosition() -> CGPoint
    /// Bounds of the active displays, in global coordinates.
    func activeDisplays() -> [CGRect]
    func isTrusted() -> Bool
    func secureInputEnabled() -> Bool
}

/// Records instead of posting. A fake 1440×900 screen and its own cursor, so
/// nothing depends on the machine running the tests.
final class LogSink: EventSink {
    let log: EventLog
    private(set) var events: [SinkEvent] = []
    var cursor = CGPoint(x: 720, y: 450)
    var screens = [CGRect(x: 0, y: 0, width: 1440, height: 900)]
    var capsLock = false
    var trusted = true
    var secureInput = false

    init(log: EventLog) {
        self.log = log
    }

    func post(_ event: SinkEvent) {
        if case let .mouse(kind, _, x, y, _, _, _, _) = event, kind == .moved || kind == .dragged {
            cursor = CGPoint(x: x, y: y)
        }
        record(event)
    }

    func toggleCapsLock() {
        capsLock.toggle()
        record(.capsLock(on: capsLock))
    }

    func capsLockIsOn() -> Bool { capsLock }
    func cursorPosition() -> CGPoint { cursor }
    func activeDisplays() -> [CGRect] { screens }
    func isTrusted() -> Bool { trusted }
    func secureInputEnabled() -> Bool { secureInput }

    func clear() {
        events.removeAll()
        log.clear()
    }

    private func record(_ event: SinkEvent) {
        events.append(event)
        log.append(event.description)
    }
}
