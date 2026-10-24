import AppKit
import SwiftUI

@main
struct RemotoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuPanel()
                .environment(appDelegate.model)
        } label: {
            MenuBarLabel()
                .environment(appDelegate.model)
        }
        .menuBarExtraStyle(.window)

        Window(Text("Welcome to \(AppInfo.name)"), id: WindowID.welcome) {
            WelcomeView()
                .environment(appDelegate.model)
        }
        .windowResizability(.contentSize)
        .windowStyle(.titleBar)
        .defaultPosition(.center)
        .suppressedAtLaunch()

        Window(Text("Pair a Phone"), id: WindowID.pair) {
            PairWindowView()
                .environment(appDelegate.model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .suppressedAtLaunch()

        Settings {
            SettingsView()
                .environment(appDelegate.model)
        }
    }
}

/// The menu bar icon. It also opens the welcome window on first launch,
/// since it is the one view that exists from the start.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: StatusIcon.image(model.menuIcon))
            .accessibilityLabel(Text(verbatim: AppInfo.name))
            .task(id: model.welcomePending) {
                guard model.welcomePending else { return }
                model.welcomePending = false
                model.prepareForWindow()
                openWindow(id: WindowID.welcome)
            }
    }
}

extension Scene {
    /// Windows here open only on request, never at launch.
    func suppressedAtLaunch() -> some Scene {
        if #available(macOS 15, *) {
            return defaultLaunchBehavior(.suppressed)
        } else {
            return self
        }
    }
}
