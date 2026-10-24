import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var windowObservers: [NSObjectProtocol] = []
    private var quitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        observeWindows()
        model.launch()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitting else { return .terminateLater }
        quitting = true
        Task {
            await model.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.pollPermissions()
        model.notifier.refreshStatus()
    }

    // MARK: Activation policy

    /// A regular app (Dock icon, ⌘-Tab) while one of our windows is open, an
    /// accessory again when they are all closed (DESIGN §4).
    private func observeWindows() {
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification] {
            windowObservers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { _ in
                    // Let the window finish closing before counting.
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { AppDelegate.updateActivationPolicy() }
                    }
                })
        }
    }

    private static func updateActivationPolicy() {
        let hasWindow = NSApp.windows.contains { window in
            window.isVisible && window.styleMask.contains(.titled) && !isMenuBarWindow(window)
        }
        let wanted: NSApplication.ActivationPolicy = hasWindow ? .regular : .accessory
        if NSApp.activationPolicy() != wanted { NSApp.setActivationPolicy(wanted) }
    }

    private static func isMenuBarWindow(_ window: NSWindow) -> Bool {
        let name = String(describing: type(of: window))
        return name.contains("MenuBarExtra") || name.contains("StatusBar") || window.level == .statusBar
            || window.level == .popUpMenu
    }
}
