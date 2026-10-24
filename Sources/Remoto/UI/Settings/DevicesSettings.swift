import RemotoCore
import SwiftUI

/// Connected and remembered phones (DESIGN §4.5).
struct DevicesSettings: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: String?
    @State private var newName = ""
    @State private var confirmForgetAll = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        Form {
            Section("Connected Now") {
                if model.connected.isEmpty {
                    Text("No phones connected").foregroundStyle(.secondary)
                }
                ForEach(model.connected) { device in
                    HStack(spacing: 10) {
                        Image(systemName: device.secure ? "lock.iphone" : "iphone")
                            .font(.title3)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: device.name)
                            Text(verbatim: [device.model, device.address, device.secure ? String(localized: "encrypted") : String(localized: "not encrypted")]
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Disconnect") { model.disconnect(device.session) }
                    }
                    .accessibilityElement(children: .contain)
                }
            }

            Section("Remembered Phones") {
                if model.trusted.isEmpty {
                    Text("Paired phones are remembered here so they can reconnect without a code.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.trusted) { device in
                    row(device)
                }
                if !model.trusted.isEmpty {
                    HStack {
                        Spacer()
                        Button("Forget All…", role: .destructive) { confirmForgetAll = true }
                    }
                }
            }
        }
        .settingsPage(height: 440)
        .onAppear { model.refreshDevices() }
        .confirmationDialog("Forget all phones?", isPresented: $confirmForgetAll) {
            Button("Forget All", role: .destructive) { model.forgetAll() }
        } message: {
            Text("They will be disconnected and their saved settings deleted. They'll need to pair again.")
        }
    }

    @ViewBuilder
    private func row(_ device: TrustedDevice) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "iphone")
                .font(.title3)
                .accessibilityHidden(true)
            if renaming == device.id {
                TextField("Name", text: $newName)
                    .focused($nameFocused)
                    .onSubmit { saveName(device) }
                Button("Save") { saveName(device) }
                    .keyboardShortcut(.defaultAction)
                Button("Cancel") { renaming = nil }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: device.name)
                    Text(verbatim: detail(device))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Rename") {
                    newName = device.name
                    renaming = device.id
                    nameFocused = true
                }
                Button("Forget", role: .destructive) { model.forget(device.id) }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func detail(_ device: TrustedDevice) -> String {
        let seen = device.lastSeen > 0 ? String(localized: "seen \(RelativeTime.string(unix: device.lastSeen))") : ""
        return [device.model, seen, device.lastAddress].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func saveName(_ device: TrustedDevice) {
        model.rename(device.id, to: newName)
        renaming = nil
    }
}
