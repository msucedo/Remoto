import AppKit
import RemotoCore
import SwiftUI
import UniformTypeIdentifiers

/// Back up, restore and reset the deck; allow shell commands (DESIGN §4.4).
struct DeckSettings: View {
    @Environment(AppModel.self) private var model
    @State private var result: (text: String, isError: Bool)?
    @State private var confirmReset = false
    @State private var confirmShell = false

    var body: some View {
        Form {
            Section("Deck") {
                Text("You edit the deck on the phone. Here you can back it up, restore it or start over.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Export…") { Task { await export() } }
                    Button("Import…") { Task { await importDeck() } }
                    Spacer()
                    Button("Reset…", role: .destructive) { confirmReset = true }
                }
                if let result {
                    Text(verbatim: result.text)
                        .font(.caption)
                        .foregroundStyle(result.isError ? .red : .secondary)
                }
            }

            Section("Shell Commands") {
                Toggle(
                    "Allow shell command buttons",
                    isOn: Binding(
                        get: { model.prefs.allowShell },
                        set: { enabled in
                            if enabled {
                                confirmShell = true
                            } else {
                                model.prefs.allowShell = false
                                model.applyConfig()
                            }
                        }))
                Text(
                    "A shell button runs any command as you. Turn this on only if every paired phone is yours. It also lets buttons open file: links."
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .settingsPage(height: 380)
        .confirmationDialog("Reset the deck?", isPresented: $confirmReset) {
            Button("Reset Deck", role: .destructive) {
                Task {
                    await model.resetDeck()
                    result = (String(localized: "The default deck is back."), false)
                }
            }
        } message: {
            Text("Every page and button goes back to the default. Export first if you want to keep them.")
        }
        .confirmationDialog("Allow shell commands?", isPresented: $confirmShell) {
            Button("Allow Shell Commands", role: .destructive) {
                model.prefs.allowShell = true
                model.applyConfig()
            }
        } message: {
            Text("Paired phones will be able to run any command on this Mac as you.")
        }
    }

    private func export() async {
        let json = await model.deckJSON()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(AppInfo.name) Deck.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(json.utf8).write(to: url, options: .atomic)
            result = (String(localized: "Saved"), false)
        } catch {
            result = (error.localizedDescription, true)
        }
    }

    private func importDeck() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let json = try String(contentsOf: url, encoding: .utf8)
            try await model.importDeck(json)
            result = (String(localized: "Imported"), false)
        } catch let error as HostError {
            result = (error.message, true)
        } catch {
            result = (error.localizedDescription, true)
        }
    }
}
