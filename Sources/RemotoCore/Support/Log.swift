import Foundation
import os

/// Logging through `os.Logger`. Callers never pass typed text or clipboard
/// contents here; messages are plain diagnostics (addresses, ids, errors).
enum Log {
    static let subsystem = "io.github.msucedo.remoto"

    enum Level: Int, Sendable, Comparable {
        case debug, info, warning, error
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    private struct State {
        var minimum: Level = .info
        var mirror = false
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())
    private static let loggers: [String: Logger] = Dictionary(
        uniqueKeysWithValues: ["net", "http", "tls", "pair", "session", "action", "store", "host"].map {
            ($0, Logger(subsystem: subsystem, category: $0))
        })

    /// `filter`: `debug`, `info`, `warning` or `error` (anything else keeps `info`).
    static func configure(filter: String, mirrorToStderr: Bool? = nil) {
        let level: Level =
            switch filter.lowercased() {
            case "debug", "trace": .debug
            case "warn", "warning": .warning
            case "error": .error
            default: .info
            }
        state.withLock {
            $0.minimum = level
            if let mirrorToStderr { $0.mirror = mirrorToStderr }
        }
    }

    static func debug(_ category: String, _ message: @autoclosure () -> String) { emit(.debug, category, message) }
    static func info(_ category: String, _ message: @autoclosure () -> String) { emit(.info, category, message) }
    static func warning(_ category: String, _ message: @autoclosure () -> String) { emit(.warning, category, message) }
    static func error(_ category: String, _ message: @autoclosure () -> String) { emit(.error, category, message) }

    private static func emit(_ level: Level, _ category: String, _ message: () -> String) {
        let (minimum, mirror) = state.withLock { ($0.minimum, $0.mirror) }
        guard level >= minimum else { return }
        let text = message()
        let logger = loggers[category] ?? Logger(subsystem: subsystem, category: category)
        switch level {
        case .debug: logger.debug("\(text, privacy: .public)")
        case .info: logger.info("\(text, privacy: .public)")
        case .warning: logger.warning("\(text, privacy: .public)")
        case .error: logger.error("\(text, privacy: .public)")
        }
        if mirror {
            FileHandle.standardError.write(Data("[\(category)] \(text)\n".utf8))
        }
    }
}
