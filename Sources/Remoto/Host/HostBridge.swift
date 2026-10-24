import Foundation
import RemotoCore
import os

/// Holds the host once it exists (the bridge is created first).
final class HostBox: Sendable {
    private let storage = OSAllocatedUnfairLock<RemotoHost?>(initialState: nil)
    var host: RemotoHost? { storage.withLock { $0 } }
    func set(_ host: RemotoHost) { storage.withLock { $0 = host } }
}

/// The app's `HostDelegate`: everything the core asks of macOS.
///
/// The core calls these methods on background threads where blocking is fine.
/// AppKit work hops to the main thread inside each service; events go to the
/// model on the main queue, in order.
final class HostBridge: HostDelegate {
    let hostBox = HostBox()
    let catalog: AppCatalog
    let clipboard: ClipboardService
    let native = NativeCommands()
    let volume: VolumeController
    let dictation: DictationService
    private let onEvent: @Sendable (HostEvent) -> Void
    private let volumeUpdates: AsyncStream<VolumeController.Reading?>.Continuation
    private let volumeTask: Task<Void, Never>

    init(
        bundleID: String,
        onEvent: @escaping @Sendable (HostEvent) -> Void,
        onSpeechAuthorization: @escaping @Sendable () -> Void
    ) {
        self.onEvent = onEvent
        catalog = AppCatalog(ownBundleID: bundleID)
        clipboard = ClipboardService(sourceID: bundleID)

        let box = hostBox
        dictation = DictationService(
            report: { session, update in box.host?.voiceUpdate(session: session, update) },
            authorizationChanged: onSpeechAuthorization)

        // Volume readings reach the core one at a time, in order.
        let (stream, continuation) = AsyncStream.makeStream(of: VolumeController.Reading?.self, bufferingPolicy: .bufferingNewest(8))
        volumeUpdates = continuation
        volume = VolumeController { reading in continuation.yield(reading) }
        volumeTask = Task {
            for await reading in stream {
                guard let host = box.host else { continue }
                if let reading {
                    await host.setVolumeState(value: reading.value, muted: reading.muted)
                } else {
                    await host.clearVolumeState()
                }
            }
        }
    }

    deinit {
        volumeUpdates.finish()
        volumeTask.cancel()
    }

    // MARK: HostDelegate

    func event(_ event: HostEvent) { onEvent(event) }

    func apps() -> [AppEntry] { catalog.apps() }

    func appIcon(id: String, sizePx: Int) -> Data? { catalog.icon(id: id, sizePx: sizePx) }

    func performApp(id: String, op: AppOp) -> Bool { catalog.perform(id: id, op: op) }

    func runNative(_ command: NativeCommand) -> Bool { native.run(command) }

    func openURL(_ url: String) -> Bool { native.openURL(url) }

    func runShortcut(name: String) -> Bool { native.runShortcut(name: name) }

    func readClipboard() -> String? { clipboard.read() }

    func writeClipboard(_ text: String) { clipboard.write(text) }

    func pasteBegin(_ text: String) -> Bool { clipboard.pasteBegin(text) }

    func pasteEnd() { clipboard.pasteEnd() }

    func setVolume(value: Float?, muted: Bool?) { volume.set(value: value, muted: muted) }

    func voiceBegin(session: UInt64, locale: String?) -> Bool { dictation.begin(session: session, locale: locale) }

    func voiceFeed(session: UInt64, pcm: Data) { dictation.feed(session: session, pcm: pcm) }

    func voiceEnd(session: UInt64, cancel: Bool) { dictation.end(session: session, cancel: cancel) }
}
