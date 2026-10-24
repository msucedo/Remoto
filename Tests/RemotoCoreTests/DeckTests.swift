import Foundation
import Testing
@testable import RemotoCore

@Suite struct DeckTests {
    func page(_ tiles: [Tile], columns: UInt8 = 4) -> Deck {
        Deck(version: 1, pages: [DeckPage(id: "p", name: "P", columns: columns, tiles: tiles)])
    }

    func tile(_ action: Action, color: String? = nil) -> Tile {
        Tile(id: "t", label: "T", color: color, icon: nil, action: action)
    }

    func message(_ deck: Deck) -> String? {
        do {
            try deck.validate()
            return nil
        } catch {
            return error.message
        }
    }

    @Test func defaultDeckIsValidAndMatchesSpec() throws {
        let deck = Deck.standard
        try deck.validate()
        #expect(deck.pages.map(\.id) == ["essentials", "apps"])
        #expect(deck.pages[0].tiles.count == 16)
        #expect(deck.pages[0].tiles.first?.action == .system(.missionControl))
        #expect(deck.pages[0].tiles.first(where: { $0.id == "screenshot" })?.action == .system(.screenshotArea))
        #expect(deck.pages[1].tiles.count == 8)
        #expect(deck.pages[1].tiles[0].icon == .app("com.apple.finder"))
        #expect(deck.pages.allSatisfy { $0.tiles.allSatisfy { $0.color == nil } })
    }

    @Test func jsonRoundTrip() throws {
        let original = Deck.standard
        let decoded = try Deck.decode(original.json.compact)
        #expect(decoded == original)
        // color and icon are omitted when absent.
        #expect(!tile(.media(.mute)).json.compact.contains("color"))
        #expect(!tile(.media(.mute)).json.compact.contains("icon"))
    }

    @Test func pageAndTileLimits() {
        #expect(message(page([], columns: 9)) != nil)
        #expect(message(page([], columns: 0)) != nil)
        #expect(message(Deck(version: 2, pages: Deck.standard.pages)) != nil)
        #expect(message(Deck(version: 1, pages: [])) != nil)
        let many = Array(repeating: tile(.media(.mute)), count: 65)
        #expect(message(page(many)) != nil)
        #expect(message(page(Array(many.prefix(64)))) == nil)
        var long = tile(.media(.mute))
        long.label = String(repeating: "é", count: 81)
        #expect(message(page([long])) != nil)
        long.label = String(repeating: "é", count: 80)
        #expect(message(page([long])) == nil)
        long.id = String(repeating: "x", count: 129)
        #expect(message(page([long])) != nil)
    }

    @Test func colors() {
        #expect(!Deck.isValidColor("#12"))
        #expect(Deck.isValidColor("#1234"))
        #expect(Deck.isValidColor("#abc"))
        #expect(Deck.isValidColor("#AABBCC"))
        #expect(Deck.isValidColor("#AABBCCDD"))
        #expect(!Deck.isValidColor("#AABBCCD"))
        #expect(!Deck.isValidColor("AABBCC"))
        #expect(!Deck.isValidColor("#GGGGGG"))
        #expect(message(page([tile(.media(.mute), color: "#12")])) != nil)
    }

    @Test func actionValidation() {
        func invalid(_ a: Action) -> Bool { (try? a.validate()) == nil }
        #expect(invalid(.keys(code: 0x100, mods: 0, char: nil)))
        #expect(invalid(.keys(code: 0, mods: 0x100, char: nil)))
        #expect(invalid(.keys(code: 0, mods: 0x20, char: nil)))
        #expect(!invalid(.keys(code: 0xFF, mods: 0x1F, char: "c")))
        #expect(invalid(.keys(code: 0, mods: 0, char: String(repeating: "x", count: 17))))
        #expect(invalid(.text(String(repeating: "x", count: 4097), enter: false)))
        #expect(invalid(.app(id: "", op: .open)))
        #expect(invalid(.url("nocolon")))
        #expect(invalid(.shortcut("")))
        #expect(invalid(.shell(String(repeating: "x", count: 4097))))
        #expect(invalid(.mouse(.left, clicks: 0)))
        #expect(invalid(.mouse(.left, clicks: 4)))
        #expect(invalid(.delay(ms: 10_001)))
        #expect(!invalid(.delay(ms: 10_000)))
        func nest(_ n: Int) -> Action { n == 0 ? .delay(ms: 1) : .sequence([nest(n - 1)]) }
        #expect(!invalid(nest(3)))
        #expect(invalid(nest(4)))
        #expect(invalid(.sequence(Array(repeating: .delay(ms: 0), count: 65))))
        #expect(!invalid(.sequence(Array(repeating: .delay(ms: 0), count: 64))))
    }

    @Test func decodingErrors() {
        #expect(throws: ActionError.self) { try Action(json: .obj([("kind", .string("warp"))])) }
        #expect(throws: ActionError.self) { try Action(json: .obj([("kind", .string("system")), ("name", .string("x"))])) }
        #expect(throws: ActionError.self) { try Deck.decode("{") }
    }

    @Test func storeFallsBackAndPersists() async throws {
        let dir = makeTempDir()
        try "{ broken".write(to: dir.appendingPathComponent("deck.json"), atomically: true, encoding: .utf8)
        let store = DeckStore(dataDir: dir)
        #expect(await store.deck == .standard)
        var deck = Deck.standard
        deck.pages[0].name = "Mine"
        try await store.replace(deck)
        let reloaded = DeckStore(dataDir: dir)
        #expect(await reloaded.deck.pages[0].name == "Mine")
        await #expect(throws: ActionError.self) { try await store.replace(page([], columns: 9)) }
        #expect(await store.deck.pages[0].name == "Mine")
    }
}
