import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import IOKit
import IOKit.hidsystem

/// FourCC 'RMTO' in `kCGEventSourceUserData`, so our own events can be recognised.
let remotoEventTag: Int64 = 0x524D_544F

/// Posts real CGEvents at the HID event tap (SPEC §10.1). Lives on the engine
/// thread only; never created by tests.
final class SystemSink: EventSink {
    private let source: CGEventSource?
    private var hidConnection: io_connect_t = 0

    init() {
        source = CGEventSource(stateID: .hidSystemState)
        source?.userData = remotoEventTag
        source?.localEventsSuppressionInterval = 0
    }

    deinit {
        closeHID()
    }

    // MARK: Posting

    func post(_ event: SinkEvent) {
        switch event {
        case let .mouse(kind, button, x, y, dx, dy, clickState, flags):
            postMouse(kind, button: button, at: CGPoint(x: x, y: y), dx: dx, dy: dy, clickState: clickState, flags: flags)
        case let .key(code, down, flags, autorepeat, text):
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
            e.flags = CGEventFlags(rawValue: flags)
            if autorepeat { e.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
            if let text {
                let units = Array(text.utf16)
                units.withUnsafeBufferPointer { e.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress) }
            }
            e.post(tap: .cghidEventTap)
        case let .flagsChanged(code, flags):
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true) else { return }
            e.type = .flagsChanged
            e.flags = CGEventFlags(rawValue: flags)
            e.post(tap: .cghidEventTap)
        case let .scroll(s):
            postScroll(s)
        case let .media(key, down):
            postMedia(key, down: down)
        case .capsLock:
            break
        }
    }

    private func postMouse(_ kind: MouseEventKind, button: MouseButton, at point: CGPoint, dx: Int64, dy: Int64, clickState: Int64, flags: UInt64) {
        let type: CGEventType
        switch (kind, button) {
        case (.moved, _): type = .mouseMoved
        case (.dragged, .left): type = .leftMouseDragged
        case (.dragged, .right): type = .rightMouseDragged
        case (.dragged, _): type = .otherMouseDragged
        case (.down, .left): type = .leftMouseDown
        case (.down, .right): type = .rightMouseDown
        case (.down, _): type = .otherMouseDown
        case (.up, .left): type = .leftMouseUp
        case (.up, .right): type = .rightMouseUp
        case (.up, _): type = .otherMouseUp
        }
        let cgButton = CGMouseButton(rawValue: UInt32(button.number)) ?? .left
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: cgButton) else { return }
        e.flags = CGEventFlags(rawValue: flags)
        e.setIntegerValueField(.mouseEventButtonNumber, value: button.number)
        switch kind {
        case .moved, .dragged:
            e.setIntegerValueField(.mouseEventDeltaX, value: dx)
            e.setIntegerValueField(.mouseEventDeltaY, value: dy)
        case .down, .up:
            e.setIntegerValueField(.mouseEventClickState, value: clickState)
        }
        e.post(tap: .cghidEventTap)
    }

    private func postScroll(_ s: ScrollEvent) {
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: s.wheel1, wheel2: s.wheel2, wheel3: 0) else { return }
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(s.phase))
        e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(s.momentum))
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(s.wheel1))
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(s.wheel2))
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: s.dy)
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: s.dx)
        e.flags = CGEventFlags(rawValue: s.flags)
        e.location = CGPoint(x: s.x, y: s.y)
        e.post(tap: .cghidEventTap)
    }

    /// System-defined event (type 14), subtype 8 (aux control buttons).
    ///
    /// SPEC §10.9 posts it with `IOHIDPostEvent` first and falls back to a
    /// CGEvent. `IOHIDPostEvent` is deprecated since macOS 11 and its own
    /// deprecation message points at posting through the event tap, so the
    /// modern path is used directly: the same event built by `NSEvent` (CGEvent
    /// has no public field for `data1`), tagged with our FourCC and posted at
    /// the HID tap.
    private func postMedia(_ key: MediaKey, down: Bool) {
        let flags = down ? KeyFlags.mediaDown : KeyFlags.mediaUp
        guard
            let ns = NSEvent.otherEvent(
                with: .systemDefined, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
                timestamp: 0, windowNumber: 0, context: nil,
                subtype: Int16(NX_SUBTYPE_AUX_CONTROL_BUTTONS),
                data1: key.data1(down: down), data2: -1),
            let e = ns.cgEvent
        else { return }
        e.setIntegerValueField(.eventSourceUserData, value: remotoEventTag)
        e.post(tap: .cghidEventTap)
    }

    // MARK: CapsLock (IOHID)

    /// The connection to the system HID service, opened lazily and reused.
    private func hid() -> io_connect_t? {
        if hidConnection != 0 { return hidConnection }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var connect: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect) == KERN_SUCCESS else { return nil }
        hidConnection = connect
        return connect
    }

    private func closeHID() {
        if hidConnection != 0 {
            IOServiceClose(hidConnection)
            hidConnection = 0
        }
    }

    func toggleCapsLock() {
        guard let h = hid() else { return }
        var state = false
        guard IOHIDGetModifierLockState(h, Int32(kIOHIDCapsLockState), &state) == KERN_SUCCESS else {
            closeHID()
            return
        }
        if IOHIDSetModifierLockState(h, Int32(kIOHIDCapsLockState), !state) != KERN_SUCCESS {
            closeHID()
        }
    }

    func capsLockIsOn() -> Bool {
        if let h = hid() {
            var state = false
            if IOHIDGetModifierLockState(h, Int32(kIOHIDCapsLockState), &state) == KERN_SUCCESS { return state }
            closeHID()
        }
        return CGEventSource.flagsState(.hidSystemState).contains(.maskAlphaShift)
    }

    // MARK: World

    func cursorPosition() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    func activeDisplays() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    func isTrusted() -> Bool { AXIsProcessTrusted() }

    func secureInputEnabled() -> Bool { IsSecureEventInputEnabled() }
}
