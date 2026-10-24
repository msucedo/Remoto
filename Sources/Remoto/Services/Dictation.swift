import AVFoundation
import Foundation
import RemotoCore
import Speech
import os

/// Dictation from the phone's microphone (SPEC §15.6): PCM Int16 LE, mono,
/// 16 kHz in; on-device speech recognition with partial results out.
///
/// Speech is split into phrases: 1.2 s after the last partial result the
/// phrase's audio is closed and its final text sent with `isFinal`, while new
/// audio already goes to the next phrase.
///
/// Every piece of state is confined to `queue` (the recognizers deliver their
/// results there too), which is why the class is `@unchecked Sendable`.
final class DictationService: @unchecked Sendable {
    private static let phrasePause: DispatchTimeInterval = .milliseconds(1200)
    private static let finalWait: DispatchTimeInterval = .milliseconds(2500)

    private let queue = DispatchQueue(label: "\(AppInfo.bundleID).dictation")
    private let resultQueue: OperationQueue
    private let report: @Sendable (UInt64, VoiceUpdate) -> Void
    private let authorizationChanged: @Sendable () -> Void
    private var sessions: [UInt64: Session] = [:]

    private final class Phrase {
        let request = SFSpeechAudioBufferRecognitionRequest()
        var task: SFSpeechRecognitionTask?
        var text = ""
        var closed = false
        var done = false
    }

    private final class Session {
        let id: UInt64
        let recognizer: SFSpeechRecognizer
        var current: Phrase?
        var closing: [Phrase] = []
        var pause: DispatchWorkItem?
        var ending = false
        var endTimer: DispatchWorkItem?
        var failures = 0

        init(id: UInt64, recognizer: SFSpeechRecognizer) {
            self.id = id
            self.recognizer = recognizer
        }
    }

    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    init(
        report: @escaping @Sendable (UInt64, VoiceUpdate) -> Void,
        authorizationChanged: @escaping @Sendable () -> Void
    ) {
        self.report = report
        self.authorizationChanged = authorizationChanged
        resultQueue = OperationQueue()
        resultQueue.maxConcurrentOperationCount = 1
        resultQueue.underlyingQueue = queue
    }

    // MARK: HostDelegate entry points

    func begin(session id: UInt64, locale: String?) -> Bool {
        queue.sync {
            if let old = sessions.removeValue(forKey: id) { cancel(old) }
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized:
                break
            case .notDetermined:
                // Asked only when dictation is first used; the system prompt shows
                // the purpose string from Info.plist.
                let changed = authorizationChanged
                SFSpeechRecognizer.requestAuthorization { _ in changed() }
                unavailable(id, String(localized: "Allow speech recognition on the Mac, then try again."))
                return true
            default:
                unavailable(id, String(localized: "Speech recognition is turned off for this app in the Mac's Privacy settings."))
                return true
            }
            guard let recognizer = Self.recognizer(for: locale) else {
                unavailable(id, String(localized: "The Mac can't recognize this language."))
                return true
            }
            guard recognizer.supportsOnDeviceRecognition else {
                unavailable(id, String(localized: "On-device dictation for this language isn't available on the Mac."))
                return true
            }
            guard recognizer.isAvailable else {
                unavailable(id, String(localized: "Dictation isn't available on the Mac right now."))
                return true
            }
            recognizer.queue = resultQueue
            let session = Session(id: id, recognizer: recognizer)
            sessions[id] = session
            startPhrase(session)
            report(id, VoiceUpdate(state: .listening))
            return true
        }
    }

    func feed(session id: UInt64, pcm: Data) {
        queue.async { [self] in
            guard let session = sessions[id], !session.ending, let buffer = makeBuffer(pcm) else { return }
            if session.current == nil { startPhrase(session) }
            session.current?.request.append(buffer)
        }
    }

    /// Int16 little-endian samples → Float32 in [-1, 1).
    private func makeBuffer(_ pcm: Data) -> AVAudioPCMBuffer? {
        let count = pcm.count / 2
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
            let samples = buffer.floatChannelData?[0]
        else { return nil }
        pcm.withUnsafeBytes { raw in
            for i in 0..<count {
                let value = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))
                samples[i] = Float(value) / 32768
            }
        }
        buffer.frameLength = AVAudioFrameCount(count)
        return buffer
    }

    func end(session id: UInt64, cancel: Bool) {
        queue.async { [self] in
            guard let session = sessions[id] else { return }
            if cancel {
                sessions[id] = nil
                self.cancel(session)
                return
            }
            session.ending = true
            session.pause?.cancel()
            if let phrase = session.current {
                phrase.closed = true
                phrase.request.endAudio()
            }
            let timer = DispatchWorkItem { [weak self, weak session] in
                guard let self, let session else { return }
                self.finish(session)
            }
            session.endTimer = timer
            queue.asyncAfter(deadline: .now() + Self.finalWait, execute: timer)
            finishIfDone(session)
        }
    }

    // MARK: Phrases (on `queue`)

    private func startPhrase(_ session: Session) {
        let phrase = Phrase()
        phrase.request.shouldReportPartialResults = true
        phrase.request.requiresOnDeviceRecognition = true
        phrase.request.addsPunctuation = true
        phrase.request.taskHint = .dictation
        session.current = phrase
        phrase.task = session.recognizer.recognitionTask(with: phrase.request) { [weak self, weak session, weak phrase] result, error in
            guard let self, let session, let phrase else { return }
            dispatchPrecondition(condition: .onQueue(self.queue))
            let text = result?.bestTranscription.formattedString
            self.handle(session, phrase, text: text, isFinal: result?.isFinal ?? false, failed: error != nil)
        }
    }

    private func handle(_ session: Session, _ phrase: Phrase, text: String?, isFinal: Bool, failed: Bool) {
        guard sessions[session.id] === session, !phrase.done else { return }
        if let text, !text.isEmpty, !isFinal, text != phrase.text {
            phrase.text = text
            session.failures = 0
            if !phrase.closed, !session.ending {
                report(session.id, VoiceUpdate(state: .listening, text: text))
                schedulePause(session, phrase)
            }
        }
        guard isFinal || failed else { return }
        if let text, !text.isEmpty { phrase.text = text }
        phrase.done = true
        session.closing.removeAll { $0 === phrase }
        let isCurrent = session.current === phrase
        if isCurrent { session.current = nil }
        if failed && phrase.text.isEmpty && !phrase.closed {
            session.failures += 1
        }
        if session.failures >= 3 {
            sessions[session.id] = nil
            cancel(session)
            report(session.id, VoiceUpdate(state: .error, message: String(localized: "Dictation stopped on the Mac.")))
            return
        }
        if session.ending {
            if isCurrent {
                finish(session, text: phrase.text)
            } else {
                if !phrase.text.isEmpty { report(session.id, VoiceUpdate(state: .listening, text: phrase.text, isFinal: true)) }
                finishIfDone(session)
            }
            return
        }
        if !phrase.text.isEmpty {
            report(session.id, VoiceUpdate(state: .listening, text: phrase.text, isFinal: true))
        }
        // The recognizer ended this phrase on its own: keep listening in a new one.
        if isCurrent { startPhrase(session) }
    }

    /// 1.2 s without new words closes the phrase; later audio starts the next.
    private func schedulePause(_ session: Session, _ phrase: Phrase) {
        session.pause?.cancel()
        let item = DispatchWorkItem { [weak self, weak session, weak phrase] in
            guard let self, let session, let phrase, session.current === phrase, !session.ending else { return }
            phrase.closed = true
            phrase.request.endAudio()
            session.closing.append(phrase)
            self.startPhrase(session)
        }
        session.pause = item
        queue.asyncAfter(deadline: .now() + Self.phrasePause, execute: item)
    }

    private func finishIfDone(_ session: Session) {
        guard session.ending, session.closing.isEmpty, session.current == nil else { return }
        finish(session)
    }

    /// Ends dictation with the last phrase's text (or none).
    private func finish(_ session: Session, text: String? = nil) {
        guard sessions[session.id] === session else { return }
        let text = text ?? session.current?.text
        sessions[session.id] = nil
        cancel(session)
        report(
            session.id,
            VoiceUpdate(state: .stopped, text: (text?.isEmpty ?? true) ? nil : text, isFinal: true))
    }

    private func cancel(_ session: Session) {
        session.pause?.cancel()
        session.endTimer?.cancel()
        for phrase in session.closing + [session.current].compactMap({ $0 }) {
            phrase.done = true
            phrase.task?.cancel()
        }
        session.closing.removeAll()
        session.current = nil
    }

    private func unavailable(_ id: UInt64, _ message: String) {
        report(id, VoiceUpdate(state: .unavailable, message: message))
    }

    /// `es-MX` → `es_MX`; falls back to another region of the same language,
    /// then to the Mac's language.
    private static func recognizer(for tag: String?) -> SFSpeechRecognizer? {
        let wanted = tag.map { Locale(identifier: $0.replacingOccurrences(of: "-", with: "_")) } ?? Locale.current
        if let recognizer = SFSpeechRecognizer(locale: wanted) { return recognizer }
        let language = wanted.language.languageCode?.identifier
        let supported = SFSpeechRecognizer.supportedLocales()
        let sameLanguage = supported.filter { $0.language.languageCode?.identifier == language }
        let preferred =
            sameLanguage.first { $0.region == Locale.current.region }
            ?? sameLanguage.sorted { $0.identifier < $1.identifier }.first
        return preferred.flatMap { SFSpeechRecognizer(locale: $0) }
    }
}
