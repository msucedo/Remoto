import Foundation

/// `deck.json` (SPEC §12). A missing or invalid file means the default deck.
actor DeckStore {
    private(set) var deck: Deck
    private let file: URL

    init(dataDir: URL) {
        file = dataDir.appendingPathComponent("deck.json")
        if let data = AtomicFile.read(file) {
            do {
                deck = try Deck.decode(String(decoding: data, as: UTF8.self))
            } catch {
                Log.warning("store", "deck.json ignored (\(error.message)); using the default deck")
                deck = .standard
            }
        } else {
            deck = .standard
        }
    }

    /// Validates and stores a deck; throws with a message for people.
    func replace(_ newDeck: Deck) throws(ActionError) {
        try newDeck.validate()
        deck = newDeck
        persist()
    }

    func replace(json text: String) throws(ActionError) {
        try replace(try Deck.decode(text))
    }

    func reset() {
        deck = .standard
        persist()
    }

    var exported: String { deck.json.pretty }

    private func persist() {
        do {
            try AtomicFile.write(deck.json.pretty, to: file)
        } catch {
            Log.error("store", "saving deck.json failed: \(error)")
        }
    }
}
