import Foundation

/// A phone's synced settings blob (SPEC §14).
struct StoredSettings: Sendable, Equatable {
    var settings: JSON
    var updatedAt: UInt64

    var wire: JSON { .obj([("settings", settings), ("updatedAt", .int(updatedAt))]) }
}

enum SettingsSaveResult: Equatable, Sendable {
    case saved
    case unchanged
    case rejected(String)
}

/// `device-settings/<hex>.json`, only for trusted devices.
actor DeviceSettingsStore {
    static let maxBytes = 131_072

    private var byID: [String: StoredSettings] = [:]
    private let folder: URL

    init(dataDir: URL, trustedIDs: Set<String>) {
        folder = dataDir.appendingPathComponent("device-settings")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let data = AtomicFile.read(file), let root = try? JSON.parse(data),
                let id = root["id"]?.stringValue, let settings = root["settings"], settings.isObject,
                let updatedAt = root["updatedAt"]?.unsigned(UInt64.self)
            else {
                Log.error("store", "\(file.lastPathComponent) is unreadable; moved aside")
                AtomicFile.quarantine(file)
                continue
            }
            guard trustedIDs.contains(id) else {
                AtomicFile.remove(file)
                continue
            }
            byID[id] = StoredSettings(settings: settings, updatedAt: updatedAt)
        }
    }

    static func fileName(for id: String) -> String {
        Secrets.hex(Secrets.sha256(id).prefix(16)) + ".json"
    }

    private func url(for id: String) -> URL { folder.appendingPathComponent(Self.fileName(for: id)) }

    func get(_ id: String) -> StoredSettings? { byID[id] }

    func save(id: String, settings: JSON, updatedAt: UInt64) -> SettingsSaveResult {
        guard settings.isObject else { return .rejected("Settings must be an object.") }
        guard settings.compact.utf8.count <= Self.maxBytes else {
            return .rejected("These settings are too large to keep on the Mac.")
        }
        if let current = byID[id] {
            if current.updatedAt > updatedAt { return .unchanged }
            if current.updatedAt == updatedAt && current.settings.compact == settings.compact { return .unchanged }
        }
        let stored = StoredSettings(settings: settings, updatedAt: updatedAt)
        byID[id] = stored
        let file = JSON.obj([
            ("version", .int(1)), ("id", .string(id)), ("settings", settings), ("updatedAt", .int(updatedAt)),
        ])
        do {
            try AtomicFile.write(file.pretty, to: url(for: id))
        } catch {
            Log.error("store", "saving device settings failed: \(error)")
        }
        return .saved
    }

    func remove(_ id: String) {
        byID.removeValue(forKey: id)
        AtomicFile.remove(url(for: id))
    }

    func removeAll() {
        for id in byID.keys { AtomicFile.remove(url(for: id)) }
        byID.removeAll()
    }

    /// Ids that have settings, with their timestamps.
    var timestamps: [String: UInt64] { byID.mapValues(\.updatedAt) }
}
