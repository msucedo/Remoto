import Foundation
@testable import RemotoCore

/// Records what the core asked the input engine to do.
final class FakeInput: InputDriver, @unchecked Sendable {
    private let lock = NSLock()
    private var _inputs: [(UInt64, Input)] = []
    private var _alive: [UInt64] = []
    private var _forgotten: [UInt64] = []
    private var _paused: [Bool] = []
    private var _trusted = true

    var inputs: [Input] { lock.withLock { _inputs.map(\.1) } }
    var aliveCount: Int { lock.withLock { _alive.count } }
    var forgotten: [UInt64] { lock.withLock { _forgotten } }
    var pausedCalls: [Bool] { lock.withLock { _paused } }
    func setTrusted(_ value: Bool) { lock.withLock { _trusted = value } }

    func send(_ input: Input, session: UInt64) { lock.withLock { _inputs.append((session, input)) } }
    func alive(session: UInt64) { lock.withLock { _alive.append(session) } }
    func forget(session: UInt64) { lock.withLock { _forgotten.append(session) } }
    func setPaused(_ paused: Bool) { lock.withLock { _paused.append(paused) } }
    func setTiming(_ timing: InputTiming) {}
    func setLayout(_ layout: KeyboardLayout?) {}
    func flush() async {}
    func shutdown() {}
    var isTrusted: Bool { lock.withLock { _trusted } }
}

/// A host delegate that records calls and can approve requests on its own.
final class FakeDelegate: HostDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [HostEvent] = []
    private var _calls: [String] = []
    private var clipboard: String?
    var autoApprove: Bool? = nil
    weak var host: RemotoHost?
    var iconPNG: Data? = Data([0x89, 0x50, 0x4E, 0x47])

    var events: [HostEvent] { lock.withLock { _events } }
    var calls: [String] { lock.withLock { _calls } }
    func clearEvents() { lock.withLock { _events.removeAll() } }

    private func record(_ call: String) { lock.withLock { _calls.append(call) } }

    func event(_ event: HostEvent) {
        lock.withLock { _events.append(event) }
        if case .approvalRequested(let request) = event, let allow = autoApprove {
            let host = self.host
            Task { await host?.respondApproval(id: request.id, allow: allow) }
        }
    }

    func apps() -> [AppEntry] {
        record("apps")
        return [AppEntry(id: "com.example.app", name: "Example", running: true, active: false, hidden: false)]
    }

    func appIcon(id: String, sizePx: Int) -> Data? {
        record("appIcon \(id) \(sizePx)")
        return iconPNG
    }

    func performApp(id: String, op: AppOp) -> Bool {
        record("performApp \(id) \(op.rawValue)")
        return id == "com.example.app"
    }

    func runNative(_ command: NativeCommand) -> Bool {
        record("runNative \(command.rawValue)")
        return true
    }

    func openURL(_ url: String) -> Bool {
        record("openURL \(url)")
        return true
    }

    func runShortcut(name: String) -> Bool {
        record("runShortcut \(name)")
        return true
    }

    func readClipboard() -> String? { lock.withLock { clipboard } }
    func writeClipboard(_ text: String) { lock.withLock { clipboard = text } }

    func pasteBegin(_ text: String) -> Bool {
        record("pasteBegin")
        return true
    }

    func pasteEnd() { record("pasteEnd") }
    func setVolume(value: Float?, muted: Bool?) { record("setVolume") }
    func voiceBegin(session: UInt64, locale: String?) -> Bool {
        record("voiceBegin")
        return true
    }
    func voiceFeed(session: UInt64, pcm: Data) { record("voiceFeed \(pcm.count)") }
    func voiceEnd(session: UInt64, cancel: Bool) { record("voiceEnd \(cancel)") }
}

/// A fresh temporary folder per test.
func makeTempDir(_ tag: String = #function) -> URL {
    let name = "remoto-tests-\(tag.filter { $0.isLetter || $0.isNumber })-\(UUID().uuidString.prefix(8))"
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Polls until `condition` holds or the timeout passes.
func eventually(timeout: Duration = .seconds(3), _ condition: () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}
