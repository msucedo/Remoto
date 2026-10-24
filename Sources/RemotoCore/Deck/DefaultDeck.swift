extension Deck {
    /// The deck a fresh install starts with (SPEC §12.4). Icons are Lucide names.
    static let standard: Deck = {
        func sys(_ id: String, _ label: String, _ icon: String, _ name: SystemAction) -> Tile {
            Tile(id: id, label: label, color: nil, icon: .symbol(icon), action: .system(name))
        }
        func media(_ id: String, _ label: String, _ icon: String, _ key: MediaKey) -> Tile {
            Tile(id: id, label: label, color: nil, icon: .symbol(icon), action: .media(key))
        }
        func app(_ bundle: String, _ label: String) -> Tile {
            Tile(id: bundle, label: label, color: nil, icon: .app(bundle), action: .app(id: bundle, op: .toggle))
        }
        let essentials = DeckPage(
            id: "essentials", name: "Essentials", columns: 4,
            tiles: [
                sys("mission-control", "Mission Control", "layout-grid", .missionControl),
                sys("app-expose", "App Windows", "app-window", .appExpose),
                sys("desktop", "Desktop", "monitor", .showDesktop),
                sys("spotlight", "Spotlight", "search", .spotlight),
                sys("space-left", "Space Left", "arrow-left-to-line", .spaceLeft),
                sys("space-right", "Space Right", "arrow-right-to-line", .spaceRight),
                sys("screenshot", "Screenshot", "scan", .screenshotArea),
                sys("lock", "Lock", "lock", .lockScreen),
                media("previous", "Previous", "skip-back", .previous),
                media("play", "Play / Pause", "play-pause", .playPause),
                media("next", "Next", "skip-forward", .next),
                media("mute", "Mute", "volume-x", .mute),
                sys("copy", "Copy", "copy", .copy),
                sys("paste", "Paste", "clipboard", .paste),
                sys("undo", "Undo", "undo", .undo),
                sys("emoji", "Emoji", "smile", .emojiPicker),
            ])
        let apps = DeckPage(
            id: "apps", name: "Apps", columns: 4,
            tiles: [
                app("com.apple.finder", "Finder"),
                app("com.apple.Safari", "Safari"),
                app("com.apple.Terminal", "Terminal"),
                app("com.apple.Music", "Music"),
                app("com.apple.MobileSMS", "Messages"),
                app("com.apple.Notes", "Notes"),
                app("com.apple.iCal", "Calendar"),
                app("com.apple.systempreferences", "Settings"),
            ])
        return Deck(version: 1, pages: [essentials, apps])
    }()
}
