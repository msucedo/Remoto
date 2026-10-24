import Foundation

/// Carries out deck actions for one session (SPEC §13.2).
struct ActionExecutor: Sendable {
    static let stoppedMessage = "Stopped because control is paused or the phone disconnected."

    let core: HostCore
    let session: SessionHandle

    private var input: InputDriver { core.input }
    private func stopped() -> Bool { core.shouldStop(session) }

    /// nil on success, otherwise a message for people.
    func run(_ action: Action, depth: Int) async -> String? {
        if stopped() { return Self.stoppedMessage }
        let id = session.id
        switch action {
        case .keys(let code, let mods, let char):
            if let char, char.count == 1, let c = char.first, c.isLetter {
                let lower = String(c).lowercased()
                let resolved = lower.count == 1 ? lower.first! : c
                input.send(.tapChar(code: code, mods: mods, char: resolved), session: id)
            } else {
                input.send(.tap(code: code, mods: mods), session: id)
            }
        case .text(let text, let enter):
            input.send(.text(text, keystrokes: false), session: id)
            if enter { input.send(.tap(code: 0x24, mods: 0), session: id) }
        case .media(let key):
            input.send(.media(key, .click), session: id)
        case .app(let appID, let op):
            let delegate = core.delegate
            let ok = await Blocking.run { delegate?.performApp(id: appID, op: op) ?? false }
            if !ok { return "That app wasn't found." }
        case .url(let url):
            if let refusal = URLPolicy.check(url, allowShell: core.config.allowShell) { return refusal }
            let delegate = core.delegate
            let ok = await Blocking.run { delegate?.openURL(url) ?? false }
            if !ok { return "The Mac couldn't open that link." }
        case .system(let name):
            switch SystemActions.step(for: name) {
            case .tap(let code, let mods):
                input.send(.tap(code: code, mods: mods), session: id)
            case .letter(let c, let code, let mods):
                input.send(.tapChar(code: code, mods: mods, char: c), session: id)
            case .native(let command):
                await input.flush()
                let delegate = core.delegate
                let ok = await Blocking.run { delegate?.runNative(command) ?? false }
                if !ok { return "The Mac couldn't do that." }
            }
        case .shortcut(let name):
            let delegate = core.delegate
            let ok = await Blocking.run { delegate?.runShortcut(name: name) ?? false }
            if !ok { return "Couldn't run that shortcut." }
        case .shell(let command):
            guard core.config.allowShell else { return "Shell commands are turned off in Remoto's settings on the Mac." }
            let core = self.core
            let session = self.session
            do {
                // Also ends when shell commands are turned off in the settings.
                try ShellRunner.launch(command, shouldStop: { core.shouldStop(session) || !core.config.allowShell })
            } catch {
                return "Couldn't run the command: \(error)"
            }
        case .mouse(let button, let clicks):
            input.send(.click(button, count: Int(min(max(clicks, 1), 3))), session: id)
        case .delay(let ms):
            await input.flush()
            var left = Int(min(ms, 10_000))
            while left > 0 {
                if stopped() { return Self.stoppedMessage }
                let chunk = min(50, left)
                try? await Task.sleep(for: .milliseconds(chunk))
                left -= chunk
            }
            if stopped() { return Self.stoppedMessage }
        case .sequence(let steps):
            if depth > Action.maxDepth { return "Sequences are nested too deep." }
            for step in steps {
                if let error = await run(step, depth: depth + 1) { return error }
            }
        }
        return nil
    }
}

/// One serial action queue per session (SPEC §13.1).
final class ActionWorker: Sendable {
    static let capacity = 32

    private struct Job: Sendable {
        var action: Action
        var id: JSON?
    }

    private let jobs: AsyncStream<Job>.Continuation
    private let waiting: Locked<Int>
    private let task: Task<Void, Never>

    init(executor: ActionExecutor) {
        let (stream, continuation) = AsyncStream.makeStream(of: Job.self)
        let waiting = Locked(0)
        jobs = continuation
        self.waiting = waiting
        task = Task {
            for await job in stream {
                waiting.withLock { $0 -= 1 }
                let error = await executor.run(job.action, depth: 0)
                if job.id != nil || error != nil {
                    executor.session.writer.send(.actionResult(id: job.id, ok: error == nil, message: error))
                }
            }
        }
    }

    /// False when 32 actions are already waiting.
    func enqueue(_ action: Action, id: JSON?) -> Bool {
        let accepted = waiting.withLock { count -> Bool in
            guard count < Self.capacity else { return false }
            count += 1
            return true
        }
        if accepted { jobs.yield(Job(action: action, id: id)) }
        return accepted
    }

    func cancel() {
        jobs.finish()
        task.cancel()
    }
}
