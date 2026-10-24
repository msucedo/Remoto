import AppKit
import CoreGraphics
import Foundation
import RemotoCore
import os

/// Mission Control, Launchpad, lock, sleep, URLs and Shortcuts (SPEC §15.5).
struct NativeCommands: Sendable {
    func run(_ command: NativeCommand) -> Bool {
        switch command {
        case .missionControl:
            return openApp(at: "/System/Applications/Mission Control.app")
        case .launchpad:
            // macOS 26 replaced Launchpad with the Apps app.
            let apps = "/System/Applications/Apps.app"
            return openApp(at: FileManager.default.fileExists(atPath: apps) ? apps : "/System/Applications/Launchpad.app")
        case .lockScreen:
            return lockScreen()
        case .sleepDisplay:
            return Self.launch("/usr/bin/pmset", ["displaysleepnow"])
        case .sleep:
            return Self.launch("/usr/bin/pmset", ["sleepnow"])
        }
    }

    func openURL(_ string: String) -> Bool {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(),
            scheme != "javascript", scheme != "data"
        else { return false }
        return MainThread.sync { NSWorkspace.shared.open(url) }
    }

    func runShortcut(name: String) -> Bool {
        // A name starting with "-" would be read as an option of `shortcuts`.
        guard !name.hasPrefix("-") else {
            Logger.app.error("refused a shortcut name that starts with \"-\"")
            return false
        }
        return Self.launch("/usr/bin/shortcuts", ["run", name])
    }

    private func openApp(at path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return false }
        MainThread.sync {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { Logger.app.error("open \(path, privacy: .public): \(error.localizedDescription, privacy: .public)") }
            }
        }
        return true
    }

    /// The system "Lock Screen" shortcut (Control-Command-Q). Without
    /// Accessibility, turning the display off locks the Mac when it asks for
    /// the password right away.
    private func lockScreen() -> Bool {
        guard AXIsProcessTrusted() else { return Self.launch("/usr/bin/pmset", ["displaysleepnow"]) }
        let source = CGEventSource(stateID: .hidSystemState)
        let qKey: CGKeyCode = 0x0C
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: qKey, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: qKey, keyDown: false)
        else { return false }
        down.flags = [.maskCommand, .maskControl]
        up.flags = [.maskCommand, .maskControl]
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// Runs a tool with no input or output and waits for it.
    private static func launch(_ path: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            Logger.app.error("\(path, privacy: .public) failed to start: \(error.localizedDescription, privacy: .public)")
            return false
        }
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            Logger.app.error("\(path, privacy: .public) exited with \(process.terminationStatus)")
            return false
        }
        return true
    }
}
