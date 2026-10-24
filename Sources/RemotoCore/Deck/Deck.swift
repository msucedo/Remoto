import Foundation

/// The button deck (SPEC §12.1). Same JSON in `deck.json` and on the wire.
struct Deck: Sendable, Equatable {
    var version: Int
    var pages: [DeckPage]
}

struct DeckPage: Sendable, Equatable {
    var id: String
    var name: String
    var columns: UInt8
    var tiles: [Tile]
}

struct Tile: Sendable, Equatable {
    var id: String
    var label: String
    var color: String?
    var icon: TileIcon?
    var action: Action
}

enum TileIcon: Sendable, Equatable {
    case symbol(String)
    case emoji(String)
    case app(String)
}

extension Deck {
    static let maxPages = 24
    static let maxTiles = 64

    // MARK: Decoding

    init(json: JSON) throws(ActionError) {
        guard json.isObject else { throw ActionError("The deck must be an object.") }
        guard let version = json["version"]?.unsigned(UInt32.self) else { throw ActionError("Unsupported deck version.") }
        guard let pages = json["pages"]?.arrayValue else { throw ActionError("The deck needs pages.") }
        var parsed: [DeckPage] = []
        for page in pages { parsed.append(try DeckPage(json: page)) }
        self.init(version: Int(version), pages: parsed)
    }

    static func decode(_ text: String) throws(ActionError) -> Deck {
        let json: JSON
        do { json = try JSON.parse(text) } catch { throw ActionError("The deck isn't valid JSON.") }
        let deck = try Deck(json: json)
        try deck.validate()
        return deck
    }

    var json: JSON { .obj([("version", .int(version)), ("pages", .array(pages.map(\.json)))]) }

    // MARK: Validation (SPEC §12.2)

    func validate() throws(ActionError) {
        guard version == 1 else { throw ActionError("Unsupported deck version.") }
        guard (1...Self.maxPages).contains(pages.count), pages.allSatisfy({ $0.tiles.count <= Self.maxTiles }) else {
            throw ActionError("The deck has too many pages or buttons.")
        }
        for page in pages {
            guard page.id.utf8.count <= 128 else { throw ActionError("An id is too long.") }
            guard page.name.unicodeScalars.count <= 80 else { throw ActionError("A label is too long.") }
            guard (1...8).contains(page.columns) else { throw ActionError("Columns must be between 1 and 8.") }
            for tile in page.tiles {
                guard tile.id.utf8.count <= 128 else { throw ActionError("An id is too long.") }
                guard tile.label.unicodeScalars.count <= 80 else { throw ActionError("A label is too long.") }
                if let color = tile.color, !Self.isValidColor(color) { throw ActionError("Invalid color.") }
                if let icon = tile.icon {
                    let ok: Bool =
                        switch icon {
                        case .app(let id): id.utf8.count <= 512
                        case .symbol(let name): name.utf8.count <= 128
                        case .emoji(let text): text.utf8.count <= 64
                        }
                    guard ok else { throw ActionError("An icon is too long.") }
                }
                try tile.action.validate(depth: 0)
            }
        }
    }

    static func isValidColor(_ color: String) -> Bool {
        let bytes = Array(color.utf8)
        guard [4, 5, 7, 9].contains(bytes.count), bytes[0] == UInt8(ascii: "#") else { return false }
        return bytes.dropFirst().allSatisfy { b in
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x46) || (b >= 0x61 && b <= 0x66)
        }
    }
}

extension DeckPage {
    init(json: JSON) throws(ActionError) {
        guard json.isObject, let id = json["id"]?.stringValue, let name = json["name"]?.stringValue,
            let tiles = json["tiles"]?.arrayValue
        else { throw ActionError("A deck page is missing id, name or tiles.") }
        guard let columns = json["columns"]?.unsigned(UInt8.self) else {
            throw ActionError("Columns must be between 1 and 8.")
        }
        var parsed: [Tile] = []
        for tile in tiles { parsed.append(try Tile(json: tile)) }
        self.init(id: id, name: name, columns: columns, tiles: parsed)
    }

    var json: JSON {
        .obj([("id", .string(id)), ("name", .string(name)), ("columns", .int(columns)), ("tiles", .array(tiles.map(\.json)))])
    }
}

extension Tile {
    init(json: JSON) throws(ActionError) {
        guard json.isObject, let id = json["id"]?.stringValue, let label = json["label"]?.stringValue,
            let action = json["action"]
        else { throw ActionError("A button is missing id, label or action.") }
        var color: String?
        if let value = json["color"], value != .null {
            guard let s = value.stringValue else { throw ActionError("Invalid color.") }
            color = s
        }
        var icon: TileIcon?
        if let value = json["icon"], value != .null {
            icon = try TileIcon(json: value)
        }
        self.init(id: id, label: label, color: color, icon: icon, action: try Action(json: action))
    }

    var json: JSON {
        .obj([
            ("id", .string(id)), ("label", .string(label)), ("color", color.map(JSON.string)), ("icon", icon?.json),
            ("action", action.json),
        ])
    }
}

extension TileIcon {
    init(json: JSON) throws(ActionError) {
        switch json["kind"]?.stringValue {
        case "symbol":
            guard let name = json["name"]?.stringValue else { break }
            self = .symbol(name)
            return
        case "emoji":
            guard let text = json["text"]?.stringValue else { break }
            self = .emoji(text)
            return
        case "app":
            guard let id = json["id"]?.stringValue else { break }
            self = .app(id)
            return
        default:
            break
        }
        throw ActionError("Invalid icon.")
    }

    var json: JSON {
        switch self {
        case .symbol(let name): .obj([("kind", .string("symbol")), ("name", .string(name))])
        case .emoji(let text): .obj([("kind", .string("emoji")), ("text", .string(text))])
        case .app(let id): .obj([("kind", .string("app")), ("id", .string(id))])
        }
    }
}
