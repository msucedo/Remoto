import AppKit
import Carbon
import Foundation
import Observation
import RemotoCore
import Speech
import os

/// The app's state and the one place that talks to `RemotoHost`.
@MainActor
@Observable
final class AppModel {
    enum ServerState: Equatable {
        case starting
        case running(port: UInt16)
        case failed(String)
        case stopped
    }

    enum Tone { case green, orange, gray, red }

    enum MenuIcon { case idle, connected, paused, request }

    struct Notice: Identifiable, Equatable {
        let id = UUID()
        var text: String
    }

    /// The live model, for callbacks that arrive outside SwiftUI.
    static private(set) weak var current: AppModel?

    let prefs: Preferences
    let webClientBundled = AppInfo.webRoot != nil

    private(set) var server: ServerState = .stopped
    private(set) var preferredPortTaken = false
    private(set) var paused = false
    private(set) var accessibilityTrusted = InputEngine.isTrusted
    private(set) var speechStatus = SFSpeechRecognizer.authorizationStatus()
    private(set) var notificationStatus: ApprovalNotifier.Status = .unknown
    private(set) var connected: [ConnectedDevice] = []
    private(set) var trusted: [TrustedDevice] = []
    private(set) var approvals: [ApprovalRequest] = []
    private(set) var pairing: PairingInfo?
    private(set) var pairingExpiresAt: Date?
    private(set) var hostName = SystemNames.hostName
    private(set) var computerName = SystemNames.computerName
    var notice: Notice?
    /// Set at launch when the welcome window should open; the menu bar label consumes it.
    var welcomePending = false

    @ObservationIgnored let host: RemotoHost
    @ObservationIgnored let bridge: HostBridge
    @ObservationIgnored let notifier = ApprovalNotifier()
    @ObservationIgnored let approvalPanel = ApprovalPanelController()
    @ObservationIgnored private let operations: AsyncStream<@Sendable () async -> Void>.Continuation
    @ObservationIgnored private let operationStream: AsyncStream<@Sendable () async -> Void>
    @ObservationIgnored private var background: [Task<Void, Never>] = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var appsDebounce: Task<Void, Never>?
    @ObservationIgnored private var pairingRefresh: Task<Void, Never>?
    @ObservationIgnored private var pinViewers = 0
    @ObservationIgnored private var pinVisibleSent = false
    @ObservationIgnored private var restarting = false
    @ObservationIgnored private var launched = false

    init() {
        let prefs = Preferences()
        self.prefs = prefs
        try? FileManager.default.createDirectory(at: AppInfo.dataDirectory, withIntermediateDirectories: true)
        RemotoHost.initLogging(prefs.logFilter.rawValue)
        bridge = HostBridge(
            bundleID: AppInfo.bundleID,
            onEvent: { event in
                DispatchQueue.main.async { MainActor.assumeIsolated { AppModel.current?.handle(event) } }
            },
            onSpeechAuthorization: {
                DispatchQueue.main.async { MainActor.assumeIsolated { AppModel.current?.pollPermissions() } }
            })
        let config = Self.config(
            prefs: prefs, hostName: SystemNames.hostName, computerName: SystemNames.computerName,
            speech: SFSpeechRecognizer.authorizationStatus())
        host = RemotoHost(config: config, delegate: bridge)
        bridge.hostBox.set(host)
        (operationStream, operations) = AsyncStream.makeStream(of: (@Sendable () async -> Void).self)
        Self.current = self
    }

    // MARK: Launch and quit

    func launch() {
        guard !launched else { return }
        launched = true
        notifier.onResponse = { [weak self] id, allow in self?.notificationResponse(id: id, allow: allow) }
        notifier.onStatusChange = { [weak self] in
            guard let self else { return }
            notificationStatus = notifier.status
        }
        notifier.setUp()
        notificationStatus = notifier.status
        bridge.catalog.setExtraFolders(prefs.appFolders)

        let stream = operationStream
        background.append(Task.detached { for await operation in stream { await operation() } })

        startServer()
        observeSystem()
        bridge.volume.start()

        background.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.pollPermissions()
            }
        })
        background.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                self?.sendTiming()
                self?.refreshNames()
            }
        })
        welcomePending = !prefs.welcomeDone
    }

    func shutdown() async {
        for task in background { task.cancel() }
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        operations.finish()
        await host.shutdown()
    }

    // MARK: Host calls, run one at a time in order

    private func perform(_ operation: @escaping @Sendable (RemotoHost) async -> Void) {
        let host = self.host
        operations.yield { await operation(host) }
    }

    private static func config(
        prefs: Preferences, hostName: String, computerName: String, speech: SFSpeechRecognizerAuthorizationStatus
    ) -> HostConfig {
        HostConfig(
            port: UInt16(clamping: prefs.port),
            dataDir: AppInfo.dataDirectory,
            webRoot: AppInfo.webRoot,
            hostName: hostName,
            computerName: computerName,
            appVersion: AppInfo.version,
            linkHost: prefs.linkHost,
            allowLocalProxy: prefs.allowLocalProxy,
            allowPin: prefs.allowPin,
            allowApproval: prefs.allowApproval,
            allowShell: prefs.allowShell,
            voiceAvailable: prefs.voiceEnabled && speech != .denied && speech != .restricted)
    }

    private var config: HostConfig {
        Self.config(prefs: prefs, hostName: hostName, computerName: computerName, speech: speechStatus)
    }

    /// Pushes preference changes that don't need a restart.
    func applyConfig() {
        let config = self.config
        perform { await $0.updateConfig(config) }
    }

    // MARK: Server

    var isRunning: Bool {
        if case .running = server { return true }
        return false
    }

    var runningPort: UInt16? {
        if case .running(let port) = server { return port }
        return nil
    }

    func startServer() {
        server = .starting
        let config = self.config
        perform { host in
            await host.updateConfig(config)
            do {
                try await host.start()
            } catch {
                let message = (error as? HostError)?.message ?? error.localizedDescription
                await MainActor.run { self.startFailed(message) }
            }
        }
    }

    func restartServer() {
        server = .starting
        restarting = true
        let config = self.config
        perform { host in
            await host.stop()
            await host.updateConfig(config)
            do {
                try await host.start()
            } catch {
                let message = (error as? HostError)?.message ?? error.localizedDescription
                await MainActor.run { self.startFailed(message) }
            }
        }
    }

    private func startFailed(_ message: String) {
        restarting = false
        if case .running = server { return }
        server = .failed(message)
    }

    /// Saves a new port and restarts the server on it.
    func applyPort(_ port: Int) {
        guard Preferences.isValidPort(port) else { return }
        prefs.port = port
        restartServer()
    }

    // MARK: Events

    func handle(_ event: HostEvent) {
        switch event {
        case .started(let port, let taken):
            restarting = false
            server = .running(port: port)
            preferredPortTaken = taken
            if taken {
                notice = Notice(
                    text: String(localized: "Port \(String(prefs.port)) was in use, so \(AppInfo.name) is using port \(String(port))."))
            }
            refreshPairing()
            refreshDevices()
            sendLayout()
            sendTiming()
            bridge.volume.refresh()
        case .stopped:
            if !restarting { server = .stopped }
            connected = []
        case .failed(let message):
            startFailed(message)
        case .sessionsChanged:
            refreshConnected()
        case .devicesChanged:
            refreshTrusted()
        case .pairingChanged:
            refreshPairing()
        case .approvalRequested(let request):
            approvals.removeAll { $0.id == request.id }
            approvals.append(request)
            if !notifier.post(request) { showApprovalPanel() }
        case .approvalEnded(let id):
            endApproval(id)
        case .paired(let name):
            notice = Notice(text: String(localized: "\(name) is now paired with this Mac."))
            refreshTrusted()
        case .notice(let message):
            // The Accessibility notice has its own callout, already localized.
            if message.localizedCaseInsensitiveContains("Accessibility") { return }
            notice = Notice(text: message)
        }
    }

    private func refreshConnected() {
        perform { host in
            let devices = await host.connectedDevices()
            await MainActor.run { self.connected = devices }
        }
    }

    private func refreshTrusted() {
        perform { host in
            let devices = await host.trustedDevices()
            await MainActor.run { self.trusted = devices }
        }
    }

    func refreshDevices() {
        refreshConnected()
        refreshTrusted()
    }

    func refreshPairing() {
        perform { host in
            let info = await host.pairingInfo()
            await MainActor.run { self.setPairing(info) }
        }
    }

    private func setPairing(_ info: PairingInfo) {
        pairing = info
        let expiry = Date().addingTimeInterval(TimeInterval(info.expiresInSecs))
        pairingExpiresAt = expiry
        pairingRefresh?.cancel()
        pairingRefresh = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, expiry.timeIntervalSinceNow + 0.5)))
            guard !Task.isCancelled else { return }
            self?.refreshPairing()
        }
    }

    func renewPairing() {
        perform { await $0.renewPairing() }
    }

    /// Cards that show the PIN call this when they appear and disappear.
    func pinCard(visible: Bool) {
        pinViewers = max(0, pinViewers + (visible ? 1 : -1))
        let now = pinViewers > 0
        guard now != pinVisibleSent else { return }
        pinVisibleSent = now
        perform { await $0.setPinVisible(now) }
        if now { refreshPairing() }
    }

    func certificate() -> Data { host.caCertificate() }

    // MARK: Approvals

    func respond(to id: UInt64, allow: Bool) {
        perform { await $0.respondApproval(id: id, allow: allow) }
        endApproval(id)
    }

    private func endApproval(_ id: UInt64) {
        approvals.removeAll { $0.id == id }
        notifier.remove(id)
        if approvals.isEmpty { approvalPanel.close() }
    }

    private func notificationResponse(id: UInt64, allow: Bool?) {
        guard approvals.contains(where: { $0.id == id }) else { return }
        if let allow {
            respond(to: id, allow: allow)
        } else {
            showApprovalPanel()
        }
    }

    func showApprovalPanel() {
        guard !approvals.isEmpty else { return }
        approvalPanel.show(model: self)
    }

    func requestNotifications() {
        notifier.requestAuthorization()
    }

    // MARK: Control

    var controlAllowed: Bool { !paused }

    func setControlAllowed(_ allowed: Bool) {
        paused = !allowed
        perform { await $0.setPaused(!allowed) }
    }

    // MARK: Devices

    func disconnect(_ session: UInt64) { perform { await $0.disconnect(session: session) } }

    func rename(_ id: String, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        perform { await $0.renameDevice(id: id, name: name) }
    }

    func forget(_ id: String) { perform { await $0.forgetDevice(id: id) } }

    func forgetAll() { perform { await $0.forgetAllDevices() } }

    // MARK: Deck

    func deckJSON() async -> String { await host.deckJSON() }

    func importDeck(_ json: String) async throws { try await host.setDeckJSON(json) }

    func resetDeck() async { await host.resetDeck() }

    // MARK: App folders

    func addAppFolder(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard !prefs.appFolders.contains(path) else { return }
        prefs.appFolders.append(path)
        appFoldersChanged()
    }

    func removeAppFolder(_ path: String) {
        prefs.appFolders.removeAll { $0 == path }
        appFoldersChanged()
    }

    private func appFoldersChanged() {
        bridge.catalog.setExtraFolders(prefs.appFolders)
        perform { await $0.appsChanged() }
    }

    // MARK: Permissions

    func pollPermissions() {
        let trusted = InputEngine.isTrusted
        if trusted != accessibilityTrusted {
            accessibilityTrusted = trusted
            perform { await $0.permissionChanged() }
        }
        let speech = SFSpeechRecognizer.authorizationStatus()
        if speech != speechStatus {
            speechStatus = speech
            applyConfig()
        }
    }

    func requestSpeech() {
        Task {
            _ = await Permissions.requestSpeech()
            pollPermissions()
        }
    }

    // MARK: System observation

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
        ]
        for name in names {
            observers.append(
                workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { AppModel.current?.appsDidChange() }
                })
        }
        let inputSource = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)
        observers.append(
            DistributedNotificationCenter.default().addObserver(forName: inputSource, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AppModel.current?.sendLayout() }
            })
    }

    /// Launches, quits, activation and hiding, debounced by 0.4 s.
    private func appsDidChange() {
        appsDebounce?.cancel()
        appsDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.perform { await $0.appsChanged() }
        }
    }

    func sendLayout() {
        guard let layout = KeyboardLayoutReader.current() else { return }
        perform { await $0.setLayout(layout) }
    }

    func sendTiming() {
        func ms(_ seconds: TimeInterval) -> UInt32 { UInt32(clamping: Int((seconds * 1000).rounded())) }
        host.setInputTiming(
            repeatDelayMs: ms(NSEvent.keyRepeatDelay), repeatIntervalMs: ms(NSEvent.keyRepeatInterval),
            doubleClickMs: ms(NSEvent.doubleClickInterval))
    }

    private func refreshNames() {
        let host = SystemNames.hostName
        let computer = SystemNames.computerName
        guard host != hostName || computer != computerName else { return }
        hostName = host
        computerName = computer
        applyConfig()
    }

    // MARK: Status

    var status: (text: String, tone: Tone) {
        switch server {
        case .starting:
            return (String(localized: "Starting…"), .orange)
        case .stopped:
            return (String(localized: "Stopped"), .gray)
        case .failed(let message):
            return (String(localized: "Couldn't start: \(message)"), .red)
        case .running(let port):
            if !approvals.isEmpty { return (String(localized: "A phone wants to connect"), .orange) }
            if paused { return (String(localized: "Paused: phones can't control this Mac"), .gray) }
            if !accessibilityTrusted { return (String(localized: "Waiting for Accessibility permission"), .orange) }
            if connected.count == 1 { return (String(localized: "Connected to \(connected[0].name)"), .green) }
            if connected.count > 1 { return (String(localized: "\(connected.count) phones connected"), .green) }
            return (String(localized: "Ready on port \(String(port))"), .green)
        }
    }

    var menuIcon: MenuIcon {
        if !approvals.isEmpty { return .request }
        if paused { return .paused }
        if !connected.isEmpty { return .connected }
        return .idle
    }

    // MARK: Windows

    /// Makes the app a regular app and brings it forward before a window opens.
    func prepareForWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func finishWelcome() {
        prefs.welcomeDone = true
    }
}
