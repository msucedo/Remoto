import AppKit
import ApplicationServices
import Foundation
import ServiceManagement
import Speech
import SystemConfiguration

/// Accessibility and speech permissions (SPEC §15.8).
@MainActor
enum Permissions {
    private static let accessibilityPane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    private static let speechPane = "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
    private static let loginItemsPane = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"

    /// Shows the system prompt (once per app) and opens Privacy › Accessibility.
    static func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openAccessibilitySettings()
    }

    static func openAccessibilitySettings() { open(accessibilityPane) }
    static func openSpeechSettings() { open(speechPane) }

    static func requestSpeech() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in continuation.resume(returning: status) }
        }
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}

/// "Open at login" with `SMAppService.mainApp`.
@MainActor
enum LoginItem {
    enum State: Equatable {
        case off, on, needsApproval, unavailable
    }

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: .on
        case .requiresApproval: .needsApproval
        case .notRegistered: .off
        case .notFound: AppInfo.isBundled ? .off : .unavailable
        @unknown default: .off
        }
    }

    /// Returns a readable error, or nil on success.
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// The Mac's names, from System Configuration.
enum SystemNames {
    /// `<LocalHostName>.local`, or "" when unknown.
    static var hostName: String {
        guard let name = SCDynamicStoreCopyLocalHostName(nil) as String?, !name.isEmpty else { return "" }
        return name + ".local"
    }

    static var computerName: String {
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty { return name }
        return Host.current().localizedName ?? "Mac"
    }
}
