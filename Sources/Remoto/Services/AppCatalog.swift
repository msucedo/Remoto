import AppKit
import Foundation
import RemotoCore
import os

/// Installed and running apps, their icons, and opening, hiding and quitting
/// them (SPEC §15.2). Safe to call from any thread.
final class AppCatalog: Sendable {
    struct Installed: Sendable {
        var id: String
        var name: String
        var url: URL
    }

    private struct RunningApp: Sendable {
        var id: String
        var name: String
        var url: URL?
        var active: Bool
        var hidden: Bool
    }

    private struct State {
        var extraFolders: [URL] = []
        var installed: [String: Installed] = [:]
        var scannedAt: ContinuousClock.Instant?
    }

    private static let cacheLifetime: Duration = .seconds(60)
    private static let standardFolders: [URL] = {
        var folders = [
            "/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
        ].map { URL(fileURLWithPath: $0, isDirectory: true) }
        folders.append(FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications"))
        return folders
    }()

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let ownID: String

    init(ownBundleID: String) {
        ownID = ownBundleID
    }

    /// Extra folders chosen by the user. Changing them drops the cache.
    func setExtraFolders(_ paths: [String]) {
        let urls = paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        state.withLock {
            $0.extraFolders = urls
            $0.scannedAt = nil
        }
    }

    // MARK: Inventory

    private func installed() -> [String: Installed] {
        let now = ContinuousClock.now
        let (cached, folders) = state.withLock { s -> ([String: Installed]?, [URL]) in
            if let at = s.scannedAt, now - at < Self.cacheLifetime { return (s.installed, s.extraFolders) }
            return (nil, s.extraFolders)
        }
        if let cached { return cached }
        let scanned = Self.scan(Self.standardFolders + folders, excluding: ownID)
        state.withLock {
            $0.installed = scanned
            $0.scannedAt = now
        }
        return scanned
    }

    private static func scan(_ folders: [URL], excluding ownID: String) -> [String: Installed] {
        var result: [String: Installed] = [:]
        var seen = Set<String>()
        func visit(_ folder: URL, depth: Int) {
            guard seen.insert(folder.standardizedFileURL.path).inserted else { return }
            let entries =
                (try? FileManager.default.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            for entry in entries {
                if entry.pathExtension == "app" {
                    guard let app = describe(entry), app.id != ownID, result[app.id] == nil else { continue }
                    result[app.id] = app
                } else if depth < 1, (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    visit(entry, depth: depth + 1)
                }
            }
        }
        for folder in folders { visit(folder, depth: 0) }
        return result
    }

    private static func describe(_ url: URL) -> Installed? {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, !id.isEmpty else { return nil }
        let name =
            [bundle.object(forInfoDictionaryKey: "CFBundleDisplayName"), bundle.object(forInfoDictionaryKey: "CFBundleName")]
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
            ?? url.deletingPathExtension().lastPathComponent
        return Installed(id: id, name: name, url: url)
    }

    private func running() -> [RunningApp] {
        let ownID = self.ownID
        return MainThread.sync {
            NSWorkspace.shared.runningApplications.compactMap { app -> RunningApp? in
                guard app.activationPolicy == .regular, !app.isTerminated, let id = app.bundleIdentifier, id != ownID
                else { return nil }
                return RunningApp(
                    id: id, name: app.localizedName ?? id, url: app.bundleURL, active: app.isActive,
                    hidden: app.isHidden)
            }
        }
    }

    /// Installed plus running apps, sorted by name.
    func apps() -> [AppEntry] {
        var entries: [String: AppEntry] = [:]
        for app in installed().values {
            entries[app.id] = AppEntry(id: app.id, name: app.name, running: false, active: false, hidden: false)
        }
        for app in running() {
            let name = entries[app.id]?.name ?? app.name
            entries[app.id] = AppEntry(id: app.id, name: name, running: true, active: app.active, hidden: app.hidden)
        }
        return entries.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func location(of id: String) -> URL? {
        if let url = running().first(where: { $0.id == id })?.url { return url }
        if let url = installed()[id]?.url { return url }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
    }

    // MARK: Icons

    /// The app's icon as a square PNG of `sizePx` pixels.
    func icon(id: String, sizePx: Int) -> Data? {
        guard let url = location(of: id) else { return nil }
        let size = min(max(sizePx, 16), 512)
        let image = NSWorkspace.shared.icon(forFile: url.path)
        return Self.png(image, pixels: size)
    }

    static func png(_ image: NSImage, pixels: Int) -> Data? {
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }
        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(
            in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: Operations

    func perform(id: String, op: AppOp) -> Bool {
        let fallbackURL = location(of: id)
        return MainThread.sync {
            let app = NSWorkspace.shared.runningApplications.first {
                $0.bundleIdentifier == id && !$0.isTerminated && $0.activationPolicy == .regular
            }
            switch op {
            case .open:
                return Self.bringForward(app, fallback: fallbackURL)
            case .toggle:
                if let app, app.isActive, !app.isHidden {
                    _ = app.hide()
                    return true
                }
                return Self.bringForward(app, fallback: fallbackURL)
            case .hide:
                guard let app else { return false }
                _ = app.hide()
                return true
            case .quit:
                guard let app else { return false }
                _ = app.terminate()
                return true
            }
        }
    }

    @MainActor
    private static func bringForward(_ app: NSRunningApplication?, fallback: URL?) -> Bool {
        if let app {
            if app.isHidden { app.unhide() }
            if app.activate(options: [.activateAllWindows]) { return true }
        }
        guard let url = app?.bundleURL ?? fallback else { return app != nil }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error { Logger.app.error("open app failed: \(error.localizedDescription, privacy: .public)") }
        }
        return true
    }
}

extension Logger {
    static let app = Logger(subsystem: AppInfo.bundleID, category: "app")
}
