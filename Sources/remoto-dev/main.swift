import Foundation
import RemotoCore

// Runs the Remoto core in a terminal, with a logging input sink by default.

struct Options {
    var webRoot: URL?
    var dataDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("remoto-dev", isDirectory: true)
    var port: UInt16 = 7979
    var approve = false
    var realInput = false
    var noInput = false
    var appVersion = "0.1.0"
    var logLevel = "info"
}

func usage() -> Never {
    print(
        """
        usage: remoto-dev [--web <dir>] [--data <dir>] [--port <n>] [--approve] [--real-input]
                          [--no-input] [--app-version <v>] [--log <level>]

          --web <dir>          web client folder to serve
          --data <dir>         data folder (default: \(Options().dataDir.path))
          --port <n>           preferred port (default 7979, 0 = any)
          --approve            approve every "ask the Mac" request automatically
          --real-input         post real keyboard and mouse events (needs Accessibility)
          --no-input           drop all input instead of logging it
          --app-version <v>    version reported to phones
          --log <level>        debug, info, warning or error
        """)
    exit(2)
}

func parseOptions() -> Options {
    var options = Options()
    var args = CommandLine.arguments.dropFirst()
    func value(_ flag: String) -> String {
        guard let v = args.popFirst() else {
            print("missing value for \(flag)")
            usage()
        }
        return v
    }
    while let arg = args.popFirst() {
        switch arg {
        case "--web": options.webRoot = URL(fileURLWithPath: value(arg), isDirectory: true)
        case "--data": options.dataDir = URL(fileURLWithPath: value(arg), isDirectory: true)
        case "--port":
            guard let port = UInt16(value(arg)) else { usage() }
            options.port = port
        case "--approve": options.approve = true
        case "--real-input": options.realInput = true
        case "--no-input": options.noInput = true
        case "--app-version": options.appVersion = value(arg)
        case "--log": options.logLevel = value(arg)
        case "-h", "--help": usage()
        default:
            print("unknown option \(arg)")
            usage()
        }
    }
    return options
}

/// Logs everything; pretends to have a few apps and an in-memory clipboard.
final class DevDelegate: HostDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var clipboard: String?
    private var savedClipboard: String?
    private var host: RemotoHost?
    let autoApprove: Bool

    init(autoApprove: Bool) { self.autoApprove = autoApprove }

    func attach(_ host: RemotoHost) {
        lock.withLock { self.host = host }
    }

    private func say(_ text: String) {
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withTime, .withColonSeparatorInTime])
        print("[\(stamp)] \(text)")
        fflush(stdout)
    }

    private var fakeApps: [AppEntry] = [
        AppEntry(id: "com.apple.finder", name: "Finder", running: true, active: true, hidden: false),
        AppEntry(id: "com.apple.Safari", name: "Safari", running: true, active: false, hidden: false),
        AppEntry(id: "com.apple.Terminal", name: "Terminal", running: false, active: false, hidden: false),
        AppEntry(id: "com.apple.Notes", name: "Notes", running: false, active: false, hidden: false),
    ]

    func event(_ event: HostEvent) {
        say("event: \(event)")
        if case .approvalRequested(let request) = event, autoApprove {
            let host = lock.withLock { self.host }
            say("auto-approving \(request.deviceName) (\(request.address))")
            Task { await host?.respondApproval(id: request.id, allow: true) }
        }
        if case .pairingChanged = event {
            let host = lock.withLock { self.host }
            Task {
                guard let info = await host?.pairingInfo() else { return }
                self.say("pairing now: \(info.link)  PIN \(info.pin)")
            }
        }
    }

    func apps() -> [AppEntry] { lock.withLock { fakeApps } }

    func appIcon(id: String, sizePx: Int) -> Data? {
        say("appIcon \(id) \(sizePx)px")
        return nil
    }

    func performApp(id: String, op: AppOp) -> Bool {
        say("performApp \(id) \(op.rawValue)")
        return lock.withLock { fakeApps.contains { $0.id == id } }
    }

    func runNative(_ command: NativeCommand) -> Bool {
        say("runNative \(command.rawValue) (not available in remoto-dev)")
        return false
    }

    func openURL(_ url: String) -> Bool {
        say("openURL \(url)")
        return true
    }

    func runShortcut(name: String) -> Bool {
        say("runShortcut \(name)")
        return true
    }

    func readClipboard() -> String? {
        say("readClipboard")
        return lock.withLock { clipboard }
    }

    func writeClipboard(_ text: String) {
        say("writeClipboard (\(text.utf8.count) bytes)")
        lock.withLock { clipboard = text }
    }

    func pasteBegin(_ text: String) -> Bool {
        say("pasteBegin (\(text.utf8.count) bytes)")
        lock.withLock {
            savedClipboard = clipboard
            clipboard = text
        }
        return true
    }

    func pasteEnd() {
        say("pasteEnd")
        lock.withLock { clipboard = savedClipboard }
    }

    func setVolume(value: Float?, muted: Bool?) {
        say("setVolume value=\(value.map { String($0) } ?? "-") muted=\(muted.map { String($0) } ?? "-")")
        let host = lock.withLock { self.host }
        Task { await host?.setVolumeState(value: value ?? 0.5, muted: muted ?? false) }
    }

    func voiceBegin(session: UInt64, locale: String?) -> Bool {
        say("voiceBegin session \(session) locale \(locale ?? "-")")
        let host = lock.withLock { self.host }
        host?.voiceUpdate(session: session, VoiceUpdate(state: .listening))
        return true
    }

    func voiceFeed(session: UInt64, pcm: Data) {}

    func voiceEnd(session: UInt64, cancel: Bool) {
        say("voiceEnd session \(session) cancel=\(cancel)")
        let host = lock.withLock { self.host }
        if !cancel { host?.voiceUpdate(session: session, VoiceUpdate(state: .stopped, isFinal: true)) }
    }
}

let options = parseOptions()
RemotoHost.initLogging(options.logLevel, mirrorToStderr: true)

let input: InputBackend =
    if options.noInput { .discard } else if options.realInput { .engine(.system) } else { .engine(.log(EventLog())) }
let localName = ProcessInfo.processInfo.hostName
let config = HostConfig(
    port: options.port,
    dataDir: options.dataDir,
    webRoot: options.webRoot,
    hostName: localName.hasSuffix(".local") ? localName : "\(localName).local",
    computerName: Host.current().localizedName ?? "Mac",
    appVersion: options.appVersion,
    allowShell: false)
let delegate = DevDelegate(autoApprove: options.approve)
let host = RemotoHost(config: config, delegate: delegate, input: input)
delegate.attach(host)

signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler {
    Task {
        print("\nstopping…")
        await host.shutdown()
        exit(0)
    }
}
sigint.resume()

Task {
    do {
        let port = try await host.start()
        await host.setPinVisible(true)
        let info = await host.pairingInfo()
        print(
            """

            Remoto core running on port \(port)
              data:        \(options.dataDir.path)
              web client:  \(options.webRoot?.path ?? "(none, placeholder page)")
              input:       \(options.noInput ? "discarded" : options.realInput ? "REAL system events" : "logged only")
              pair link:   \(info.link)
              PIN:         \(info.pin)
              addresses:   \(info.addresses.joined(separator: ", "))
              CA SHA-256:  \(info.caFingerprint.isEmpty ? "(no TLS identity)" : info.caFingerprint)

            """)
        fflush(stdout)
    } catch {
        print("failed to start: \(error)")
        exit(1)
    }
}

dispatchMain()
