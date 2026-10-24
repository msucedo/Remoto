import Foundation
import NIOCore

/// Drives one WebSocket connection from `hello` to the end (SPEC §6.4, §8, §9).
/// Owned by a single task; everything that happens to the session arrives as
/// a `SessionEvent` on one stream, so handling is strictly ordered.
final class SessionRunner {
    static let helloTimeout: Duration = .seconds(10)
    static let silenceLimit: Double = 8
    static let maxText = 65_536
    static let maxBlocking = 8

    private enum Phase {
        case hello
        case approving(id: UInt64, hello: Hello)
        case active(SessionHandle)
        case finished
    }

    private let core: HostCore
    private let channel: Channel
    private let writer: FrameWriter
    private let peer: PeerInfo
    private let events: AsyncStream<SessionEvent>
    private let control: AsyncStream<SessionEvent>.Continuation
    private let flow: InboundFlow
    private let blocking = Locked(0)
    private let voiceQueue = DispatchQueue(label: "remoto-voice", qos: .userInitiated)

    private var phase: Phase = .hello
    private var lastSeen = Mono.now()
    private var voiceActive = false
    private var worker: ActionWorker?
    private var timers: [Task<Void, Never>] = []
    private var finalWrite: EventLoopFuture<Void>?

    init(
        core: HostCore, channel: Channel, peer: PeerInfo, events: AsyncStream<SessionEvent>,
        control: AsyncStream<SessionEvent>.Continuation, flow: InboundFlow
    ) {
        self.core = core
        self.channel = channel
        self.writer = FrameWriter(channel: channel)
        self.peer = peer
        self.events = events
        self.control = control
        self.flow = flow
    }

    func run() async {
        let control = self.control
        let timeout = Self.helloTimeout
        timers.append(
            Task {
                try? await Task.sleep(for: timeout)
                if !Task.isCancelled { control.yield(.helloTimeout) }
            })
        for await event in events {
            flow.consumed(event.inboundBytes)
            guard await handle(event) else { break }
        }
        await finish()
    }

    // MARK: Event dispatch

    /// Returns false when the session is over.
    private func handle(_ event: SessionEvent) async -> Bool {
        switch phase {
        case .hello:
            return await handleHello(event)
        case .approving(let id, let hello):
            return await handleApproving(event, id: id, hello: hello)
        case .active(let session):
            return await handleActive(event, session: session)
        case .finished:
            return false
        }
    }

    private func handleHello(_ event: SessionEvent) async -> Bool {
        switch event {
        case .text(let text, _):
            cancelTimers()
            return await authenticate(text)
        case .helloTimeout, .closed:
            return false
        case .bye(let reason, let reconnect):
            closeWith(.bye(reason: reason, reconnect: reconnect))
            return false
        default:
            // Binary frames and anything else are ignored until `hello`.
            return true
        }
    }

    private func handleApproving(_ event: SessionEvent, id: UInt64, hello: Hello) async -> Bool {
        switch event {
        case .text(let text, _):
            if case .ping(let pingID)? = try? ClientMessage.decode(text) { writer.send(.pong(id: pingID)) }
            return true
        case .approval(let decision):
            cancelTimers()
            await endApproval(id: id, approved: decision == true)
            guard decision == true else {
                closeWith(.denied(.rejected, retryAfter: nil))
                return false
            }
            await accept(hello, method: .approve, name: TextClean.displayName(hello.name))
            return true
        case .closed:
            await endApproval(id: id, approved: false)
            return false
        case .bye(let reason, let reconnect):
            await endApproval(id: id, approved: false)
            closeWith(.bye(reason: reason, reconnect: reconnect))
            return false
        default:
            return true
        }
    }

    private func handleActive(_ event: SessionEvent, session: SessionHandle) async -> Bool {
        switch event {
        case .text(let text, _):
            lastSeen = Mono.now()
            await handleMessage(text, session: session)
        case .binary(let bytes):
            lastSeen = Mono.now()
            handleBinary(bytes, session: session)
        case .tick:
            if Mono.now() - lastSeen > Self.silenceLimit {
                Log.info("session", "session \(session.id) went silent; closing")
                return false
            }
        case .closed:
            return false
        case .bye(let reason, let reconnect):
            closeWith(.bye(reason: reason, reconnect: reconnect))
            return false
        case .voiceUpdate(let update):
            if update.state != .listening { voiceActive = false }
            writer.send(.voice(update))
        case .voiceBeginFailed:
            if voiceActive {
                voiceActive = false
                writer.send(.voice(VoiceUpdate(state: .unavailable, isFinal: false, message: "Dictation isn't available on the Mac.")))
            }
        case .send(let message):
            writer.send(message)
        case .helloTimeout, .approval:
            break
        }
        return true
    }

    // MARK: Handshake (SPEC §8.1)

    private func authenticate(_ text: String) async -> Bool {
        let json = try? JSON.parse(text)
        // A hello from a different protocol version may not decode at all.
        if let json, json["t"]?.stringValue == "hello", let v = json["v"], v.unsigned(UInt32.self) != 1 {
            closeWith(.denied(.incompatible, retryAfter: nil))
            return false
        }
        guard let json, case .hello(let hello)? = try? ClientMessage.decode(json) else {
            closeWith(.bye(reason: "Expected a hello message first.", reconnect: false))
            return false
        }
        let idBytes = Array(hello.deviceID.utf8)
        guard (1...128).contains(idBytes.count), idBytes.allSatisfy({ (0x21...0x7E).contains($0) }) else {
            closeWith(.denied(.incompatible, retryAfter: nil))
            return false
        }
        let config = core.config
        switch hello.auth {
        case .token(let token):
            guard
                let name = await core.trust.verify(
                    id: hello.deviceID, token: token, helloName: hello.name, ip: peer.ip)
            else { return deny(.denied(.unknown)) }
            await accept(hello, method: hello.auth, name: name)
        case .pair(let code):
            let (outcome, changed) = await core.pairing.checkCode(code)
            if changed { core.emit(.pairingChanged) }
            guard outcome == .ok else { return deny(outcome) }
            await accept(hello, method: hello.auth, name: TextClean.displayName(hello.name))
        case .pin(let pin):
            guard config.allowPin else { return deny(.denied(.rejected)) }
            let (outcome, changed) = await core.pairing.checkPin(pin, ip: peer.ip)
            if changed { core.emit(.pairingChanged) }
            guard outcome == .ok else { return deny(outcome) }
            await accept(hello, method: hello.auth, name: TextClean.displayName(hello.name))
        case .approve:
            return await beginApproval(hello)
        }
        return true
    }

    private func deny(_ outcome: AuthOutcome) -> Bool {
        if case .denied(let reason, let retryAfter) = outcome {
            closeWith(.denied(reason, retryAfter: retryAfter))
        }
        return false
    }

    private func beginApproval(_ hello: Hello) async -> Bool {
        guard core.config.allowApproval else { return deny(.denied(.rejected)) }
        let id = core.nextID()
        let name = TextClean.displayName(hello.name)
        let lookalike = await core.trust.devices().contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        let request = ApprovalRequest(
            id: id, deviceName: name, model: TextClean.clean(hello.model, max: 64), address: peer.ip,
            nameMatchesTrustedDevice: lookalike)
        switch await core.pairing.beginApproval(id: id, ip: peer.ip) {
        case .denied(let outcome):
            return deny(outcome)
        case .started:
            break
        }
        phase = .approving(id: id, hello: hello)
        core.emit(.approvalRequested(request))
        writer.send(.pending)
        let control = self.control
        let pairing = core.pairing
        timers.append(
            Task {
                let decision = await pairing.waitForDecision(id: id)
                if let decision { control.yield(.approval(decision)) }
            })
        timers.append(
            Task {
                try? await Task.sleep(for: .secondsDouble(PairingManager.approvalTimeout))
                if !Task.isCancelled { control.yield(.approval(nil)) }
            })
        return true
    }

    private func endApproval(id: UInt64, approved: Bool) async {
        await core.pairing.endApproval(id: id, ip: peer.ip, approved: approved)
        core.emit(.approvalEnded(id))
    }

    /// SPEC §6.5 and §8.2.
    private func accept(_ hello: Hello, method: HelloAuth, name: String) async {
        let byToken: Bool
        if case .token = method { byToken = true } else { byToken = false }
        let remembered = byToken || hello.remember
        var token: String?
        if !byToken && hello.remember {
            token = await core.trust.issue(id: hello.deviceID, name: hello.name, model: hello.model, ip: peer.ip)
        }
        let session = SessionHandle(
            id: core.nextID(), deviceID: hello.deviceID, name: name, model: TextClean.clean(hello.model, max: 64),
            peer: peer, remembered: remembered, sessionKey: Secrets.randomToken(18), writer: writer, events: control)
        let config = core.config
        let runtime = core.runtime.value
        let settings = remembered ? await core.settings.get(hello.deviceID) : nil
        let welcome = Welcome(
            hostName: config.computerName, hostVersion: config.appVersion, sessionKey: session.sessionKey,
            token: token, features: core.features(secure: peer.secure), deck: await core.deck.deck,
            layout: runtime.layout, volume: runtime.volume, paused: runtime.paused, settings: settings)
        flow.authenticated()
        writer.send(.welcome(welcome))
        await core.sessions.add(session)
        worker = ActionWorker(executor: ActionExecutor(core: core, session: session))
        phase = .active(session)
        lastSeen = Mono.now()
        if !byToken { core.emit(.paired(name)) }
        if remembered { core.emit(.devicesChanged) }
        core.emit(.sessionsChanged)
        Log.info("session", "session \(session.id) connected from \(peer.ip) (\(method.methodName))")
        let control = self.control
        timers.append(
            Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    control.yield(.tick)
                }
            })
    }

    // MARK: Messages (SPEC §9.1)

    private func notice(_ level: NoticeLevel, _ code: NoticeCode?, _ message: String) {
        writer.send(.notice(level, code: code, message: message))
    }

    private func tooLong() {
        notice(.warning, .tooLong, "That text is too long to send in one go.")
    }

    /// Runs a delegate call off the loop, at most 8 at a time per connection.
    private func blockingTask(_ body: @escaping @Sendable () async -> Void) {
        let started = blocking.withLock { count -> Bool in
            guard count < Self.maxBlocking else { return false }
            count += 1
            return true
        }
        guard started else {
            notice(.warning, .busy, "The Mac is busy. Try again in a moment.")
            return
        }
        let counter = blocking
        Task {
            await body()
            counter.withLock { $0 -= 1 }
        }
    }

    private func handleMessage(_ text: String, session: SessionHandle) async {
        let message: ClientMessage
        do {
            message = try ClientMessage.decode(text)
        } catch {
            Log.debug("session", "ignored message from session \(session.id): \(error.reason)")
            core.input.send(.release, session: session.id)
            return
        }
        let id = session.id
        let input = core.input
        let core = self.core
        let writer = self.writer
        switch message {
        case .hello:
            break
        case .ping(let pingID):
            writer.send(.pong(id: pingID))
        case .key(let code, let down, let mods, let repeats):
            input.send(.key(code: code, down: down, mods: mods, repeats: repeats), session: id)
        case .tap(let code, let mods):
            guard code < 0x100, mods & 0xF0E0 == 0 else { break }
            input.send(.tap(code: code, mods: mods), session: id)
        case .button(let button, let op):
            input.send(.button(button, op), session: id)
        case .media(let key, let op):
            input.send(.media(key, op), session: id)
        case .volume(let value, let muted):
            let clamped = value.flatMap { $0.isFinite ? min(max($0, 0), 1) : nil }
            guard clamped != nil || muted != nil else { break }
            blockingTask {
                let delegate = core.delegate
                await Blocking.run { delegate?.setVolume(value: clamped, muted: muted) }
            }
        case .text(let text, let mode):
            guard text.utf8.count <= Self.maxText else { return tooLong() }
            guard !core.isPaused else {
                return notice(.warning, .paused, "Control is paused on the Mac.")
            }
            switch mode {
            case .unicode: input.send(.text(text, keystrokes: false), session: id)
            case .keystrokes: input.send(.text(text, keystrokes: true), session: id)
            case .paste: paste(text, session: session)
            }
        case .edit(let delete, let insert):
            guard insert.utf8.count <= Self.maxText else { return tooLong() }
            input.send(.edit(delete: Int(min(delete, 4096)), insert: insert), session: id)
        case .release:
            input.send(.release, session: id)
        case .action(let action, let actionID):
            do {
                try action.validate(depth: 0)
            } catch {
                writer.send(.actionResult(id: actionID, ok: false, message: error.message))
                break
            }
            if worker?.enqueue(action, id: actionID) != true {
                writer.send(
                    .actionResult(id: actionID, ok: false, message: "The Mac is still busy with earlier actions."))
            }
        case .apps:
            blockingTask {
                let delegate = core.delegate
                let apps = await Blocking.run { delegate?.apps() ?? [] }
                writer.send(.apps(apps))
            }
        case .appAction(let appID, let op):
            blockingTask {
                let delegate = core.delegate
                let ok = await Blocking.run { delegate?.performApp(id: appID, op: op) ?? false }
                if !ok { writer.send(.notice(.error, code: nil, message: "That app wasn't found on the Mac.")) }
            }
        case .deckSave(let json):
            do {
                let deck = try Deck(json: json)
                try await core.deck.replace(deck)
                await core.broadcast(.deck(deck))
            } catch {
                notice(.error, .deck, error.message)
            }
        case .voiceStart(let locale):
            guard core.config.voiceAvailable else {
                writer.send(.voice(VoiceUpdate(state: .unavailable, message: "Dictation is turned off on the Mac.")))
                break
            }
            voiceActive = true
            let control = self.control
            voiceQueue.async {
                let ok = core.delegate?.voiceBegin(session: id, locale: locale) ?? false
                if !ok { control.yield(.voiceBeginFailed) }
            }
        case .voiceStop(let cancel):
            guard voiceActive else { break }
            voiceActive = false
            voiceQueue.async { core.delegate?.voiceEnd(session: id, cancel: cancel) }
        case .clipboardSet(let text):
            guard text.utf8.count <= Self.maxText else { return tooLong() }
            blockingTask {
                let delegate = core.delegate
                await Blocking.run { delegate?.writeClipboard(text) }
            }
        case .clipboardGet:
            blockingTask {
                let delegate = core.delegate
                let text = await Blocking.run { delegate?.readClipboard() }
                writer.send(.clipboard(text))
            }
        case .settingsSave(let settings, let updatedAt):
            guard session.remembered else { break }
            if case .rejected(let reason) = await core.settings.save(
                id: session.deviceID, settings: settings, updatedAt: updatedAt)
            {
                notice(.error, nil, reason)
            }
        case .settingsList:
            guard session.remembered else {
                return notice(.warning, .settings, "Turn on “Remember this device” to see other devices' settings.")
            }
            writer.send(.settingsList(await core.settingsList(excluding: session.deviceID)))
        case .settingsCopy(let from):
            guard session.remembered else {
                return notice(.warning, .settings, "Turn on “Remember this device” to copy settings.")
            }
            guard let stored = await core.settings.get(from) else {
                return notice(.warning, .settings, "Those settings are no longer on the Mac.")
            }
            writer.send(.settings(stored))
        }
    }

    /// SPEC §11.5.
    private func paste(_ text: String, session: SessionHandle) {
        let core = self.core
        let writer = self.writer
        blockingTask {
            guard !core.shouldStop(session) else { return }
            let delegate = core.delegate
            let ok = await Blocking.run { delegate?.pasteBegin(text) ?? false }
            guard ok else {
                writer.send(.notice(.error, code: nil, message: "Couldn't use the clipboard on the Mac."))
                return
            }
            core.input.send(.tapChar(code: 0x09, mods: Mods.cmd, char: "v"), session: session.id)
            await core.input.flush()
            try? await Task.sleep(for: .milliseconds(450))
            await Blocking.run { delegate?.pasteEnd() }
        }
    }

    /// SPEC §9.2.
    private func handleBinary(_ bytes: [UInt8], session: SessionHandle) {
        let input = core.input
        let id = session.id
        input.alive(session: id)
        guard let frame = BinaryFrame.decode(bytes) else { return }
        switch frame {
        case .move(let dx, let dy): input.send(.move(dx: dx, dy: dy), session: id)
        case .scroll(let phase, let dx, let dy): input.send(.scroll(phase: phase, dx: dx, dy: dy), session: id)
        case .fling(let vx, let vy): input.send(.fling(vx: vx, vy: vy), session: id)
        case .touch: input.send(.touch, session: id)
        case .audio(let pcm):
            guard voiceActive, !core.shouldStop(session) else { return }
            let core = self.core
            voiceQueue.async { core.delegate?.voiceFeed(session: id, pcm: pcm) }
        }
    }

    // MARK: Ending

    private func closeWith(_ message: ServerMessage) {
        finalWrite = writer.send(message)
    }

    private func cancelTimers() {
        for timer in timers { timer.cancel() }
        timers.removeAll()
    }

    private func finish() async {
        let previous = phase
        phase = .finished
        cancelTimers()
        if case .approving(let id, _) = previous {
            await endApproval(id: id, approved: false)
        }
        if case .active(let session) = previous {
            session.markDisconnected()
            await core.sessions.remove(session.id)
            core.input.forget(session: session.id)
            worker?.cancel()
            if voiceActive {
                voiceActive = false
                let core = self.core
                let id = session.id
                voiceQueue.async { core.delegate?.voiceEnd(session: id, cancel: true) }
            }
            core.emit(.sessionsChanged)
            Log.info("session", "session \(session.id) ended")
        }
        if let finalWrite { _ = try? await finalWrite.get() }
        try? await channel.close()
        control.finish()
    }
}
