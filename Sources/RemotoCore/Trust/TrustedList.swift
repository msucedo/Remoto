import Foundation

/// One remembered phone. Only the token's SHA-256 is kept (SPEC §7.1).
struct TrustedEntry: Sendable, Equatable {
    var id: String
    var name: String
    var model: String
    var pairedAt: Int64
    var lastSeen: Int64
    var lastAddress: String
    var tokenHash: String

    var json: JSON {
        .obj([
            ("id", .string(id)), ("name", .string(name)), ("model", .string(model)),
            ("pairedAt", .int(pairedAt)), ("lastSeen", .int(lastSeen)),
            ("lastAddress", .string(lastAddress)), ("tokenHash", .string(tokenHash)),
        ])
    }

    init(
        id: String, name: String, model: String, pairedAt: Int64, lastSeen: Int64, lastAddress: String,
        tokenHash: String
    ) {
        self.id = id
        self.name = name
        self.model = model
        self.pairedAt = pairedAt
        self.lastSeen = lastSeen
        self.lastAddress = lastAddress
        self.tokenHash = tokenHash
    }

    init?(json: JSON) {
        guard let id = json["id"]?.stringValue, let name = json["name"]?.stringValue,
            let tokenHash = json["tokenHash"]?.stringValue,
            let pairedAt = json["pairedAt"]?.doubleValue, let lastSeen = json["lastSeen"]?.doubleValue,
            tokenHash.utf8.count == 64, tokenHash.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) || ($0 >= 0x41 && $0 <= 0x46) })
        else { return nil }
        self.init(
            id: id, name: name, model: json["model"]?.stringValue ?? "", pairedAt: Int64(pairedAt),
            lastSeen: Int64(lastSeen), lastAddress: json["lastAddress"]?.stringValue ?? "",
            tokenHash: tokenHash.lowercased())
    }
}

/// The trusted device list and its rules (SPEC §7.2–§7.4), without I/O.
struct TrustedList: Sendable, Equatable {
    static let maxDevices = 64
    private(set) var entries: [TrustedEntry] = []

    init(entries: [TrustedEntry] = []) { self.entries = entries }

    /// Parses `trusted.json`; nil when it is not a valid file.
    static func decode(_ data: Data) -> TrustedList? {
        guard let root = try? JSON.parse(data), root["version"] != nil,
            let devices = root["devices"]?.arrayValue
        else { return nil }
        var list = TrustedList()
        for item in devices {
            // One damaged entry costs only that device, not the whole list.
            guard let entry = TrustedEntry(json: item) else {
                Log.warning("store", "skipped an unreadable entry in trusted.json")
                continue
            }
            list.entries.append(entry)
        }
        return list
    }

    func encode() -> String {
        JSON.obj([("version", .int(1)), ("devices", .array(entries.map(\.json)))]).pretty
    }

    /// Adds or replaces a device and returns the new plain token.
    mutating func issue(id: String, name: String, model: String, ip: String, now: Int64) -> String {
        let token = Secrets.randomToken(32)
        let cleanID = TextClean.clean(id, max: 128)
        entries.removeAll { $0.id == cleanID || $0.id == id }
        while entries.count >= Self.maxDevices,
            let oldest = entries.indices.min(by: { entries[$0].lastSeen < entries[$1].lastSeen })
        {
            entries.remove(at: oldest)
        }
        entries.append(
            TrustedEntry(
                id: cleanID, name: TextClean.displayName(name), model: TextClean.clean(model, max: 64),
                pairedAt: now, lastSeen: now, lastAddress: ip, tokenHash: Secrets.sha256Hex(token)))
        return token
    }

    enum VerifyResult: Equatable {
        case unknown
        /// `name` is the presented name; `needsSave` follows the rules of §7.3.
        case ok(name: String, needsSave: Bool)
    }

    mutating func verify(id: String, token: String, helloName: String, ip: String, now: Int64) -> VerifyResult {
        let digest = Array(Secrets.sha256Hex(token).utf8)
        var match: Int?
        // Look at every entry so timing doesn't depend on where the match is.
        for (i, entry) in entries.enumerated() {
            let same = Secrets.constantTimeEquals(digest, Array(entry.tokenHash.utf8))
            if same && entry.id == id && match == nil { match = i }
        }
        guard let i = match else { return .unknown }
        var entry = entries[i]
        let previousSeen = entry.lastSeen
        var changed = false
        if entry.lastAddress != ip {
            entry.lastAddress = ip
            changed = true
        }
        entry.lastSeen = now
        let offered = TextClean.clean(helloName, max: 64)
        if entry.name.unicodeScalars.first != TextClean.renamedMark, !offered.isEmpty, offered != entry.name {
            entry.name = offered
            changed = true
        }
        entries[i] = entry
        let stale = now - previousSeen >= 3600
        return .ok(name: TextClean.presented(entry.name), needsSave: changed || stale)
    }

    /// Returns false when the id isn't known.
    mutating func rename(id: String, name: String) -> Bool {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return false }
        entries[i].name = String(TextClean.renamedMark) + TextClean.clean(name, max: 64)
        return true
    }

    mutating func remove(id: String) -> Bool {
        let before = entries.count
        entries.removeAll { $0.id == id }
        return entries.count != before
    }

    mutating func removeAll() { entries.removeAll() }

    func contains(id: String) -> Bool { entries.contains { $0.id == id } }
}

/// `trusted.json` on disk (SPEC §7.1).
actor TrustStore {
    private var list: TrustedList
    private let file: URL
    /// The ids loaded at startup (used to purge settings of forgotten devices).
    nonisolated let initialIDs: Set<String>

    init(dataDir: URL) {
        file = dataDir.appendingPathComponent("trusted.json")
        if let data = AtomicFile.read(file) {
            if let decoded = TrustedList.decode(data) {
                list = decoded
            } else {
                Log.error("store", "trusted.json is unreadable; moved aside as trusted.json.corrupt")
                AtomicFile.quarantine(file)
                list = TrustedList()
            }
        } else {
            list = TrustedList()
        }
        initialIDs = Set(list.entries.map(\.id))
    }

    private func save() {
        do {
            try AtomicFile.write(list.encode(), to: file)
        } catch {
            Log.error("store", "saving trusted.json failed: \(error)")
        }
    }

    func issue(id: String, name: String, model: String, ip: String) -> String {
        let token = list.issue(id: id, name: name, model: model, ip: ip, now: Unix.now())
        save()
        return token
    }

    /// The presented name, or nil for an unknown id/token pair.
    func verify(id: String, token: String, helloName: String, ip: String) -> String? {
        switch list.verify(id: id, token: token, helloName: helloName, ip: ip, now: Unix.now()) {
        case .unknown:
            return nil
        case .ok(let name, let needsSave):
            if needsSave { save() }
            return name
        }
    }

    func rename(id: String, name: String) -> Bool {
        guard list.rename(id: id, name: name) else { return false }
        save()
        return true
    }

    func remove(id: String) -> Bool {
        guard list.remove(id: id) else { return false }
        save()
        return true
    }

    func removeAll() {
        list.removeAll()
        save()
    }

    func contains(id: String) -> Bool { list.contains(id: id) }

    var ids: Set<String> { Set(list.entries.map(\.id)) }

    var entries: [TrustedEntry] { list.entries }

    func devices() -> [TrustedDevice] {
        list.entries.sorted { $0.lastSeen > $1.lastSeen }.map {
            TrustedDevice(
                id: $0.id, name: TextClean.presented($0.name), model: $0.model, pairedAt: $0.pairedAt,
                lastSeen: $0.lastSeen, lastAddress: $0.lastAddress)
        }
    }
}
