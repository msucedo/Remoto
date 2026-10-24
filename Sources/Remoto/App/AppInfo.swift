import AppKit
import Foundation

/// Product identity, read back from the bundle (the build script fills it in
/// from `product.env`). The literals are only fallbacks for `swift run`.
enum AppInfo {
    static var name: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? "Remoto"
    }

    static var bundleID: String { Bundle.main.bundleIdentifier ?? "io.github.msucedo.remoto" }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    /// True when running from an assembled `.app` (not `swift run`).
    static var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static let repositoryURL = URL(string: "https://github.com/msucedo/remoto")!
    static let issuesURL = URL(string: "https://github.com/msucedo/remoto/issues")!
    static let licenseURL = URL(string: "https://github.com/msucedo/remoto/blob/main/LICENSE")!

    /// `~/Library/Application Support/<Name>`.
    static var dataDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        return base.appending(path: name, directoryHint: .isDirectory)
    }

    /// The bundled phone client, or nil in builds without it.
    static var webRoot: URL? {
        guard let url = Bundle.main.resourceURL?.appending(path: "web", directoryHint: .isDirectory),
            FileManager.default.fileExists(atPath: url.appending(path: "index.html").path)
        else { return nil }
        return url
    }

    /// Path where the core serves the local CA to phones.
    static let certificatePath = "/remoto.crt"
}

/// Runs `body` on the main thread and waits for it. For `HostDelegate`
/// methods, which arrive on background threads that are allowed to block.
enum MainThread {
    static func sync<T: Sendable>(_ body: @MainActor () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated { body() } }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { body() } }
    }
}
