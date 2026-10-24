import Speech
import SwiftUI

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var loginState = LoginItem.state
    @State private var loginError: String?

    var body: some View {
        @Bindable var prefs = model.prefs
        Form {
            Section("Control") {
                Toggle(
                    "Allow phones to control this Mac",
                    isOn: Binding(get: { model.controlAllowed }, set: { model.setControlAllowed($0) }))
                PermissionRow(
                    title: Text("Accessibility"),
                    detail: model.accessibilityTrusted
                        ? Text("Phones can move the pointer and type.")
                        : Text("Needed to move the pointer and type. Allow \(AppInfo.name) in Privacy & Security › Accessibility."),
                    granted: model.accessibilityTrusted
                ) {
                    Button("Request…") { Permissions.requestAccessibility() }
                    Button("Open Settings") { Permissions.openAccessibilitySettings() }
                }
            }

            Section("Dictation") {
                Toggle("Allow dictation from phones", isOn: $prefs.voiceEnabled)
                    .onChange(of: prefs.voiceEnabled) { model.applyConfig() }
                PermissionRow(
                    title: Text("Speech Recognition"),
                    detail: Text(
                        "Speech is turned into text on this Mac, never on a server. Phones need an encrypted (https) connection to use the microphone."
                    ),
                    granted: model.speechStatus == .authorized
                ) {
                    if model.speechStatus == .notDetermined {
                        Button("Allow…") { model.requestSpeech() }
                    } else {
                        Button("Open Settings") { Permissions.openSpeechSettings() }
                    }
                }
            }

            Section("Startup") {
                Toggle(
                    "Open at login",
                    isOn: Binding(
                        get: { loginState == .on || loginState == .needsApproval },
                        set: { enabled in
                            loginError = LoginItem.set(enabled)
                            loginState = LoginItem.state
                        })
                )
                .disabled(loginState == .unavailable)
                if loginState == .needsApproval {
                    HStack {
                        Text("macOS is waiting for you to approve it in System Settings › General › Login Items.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items") { LoginItem.openSettings() }
                    }
                }
                if let loginError {
                    Text(verbatim: loginError).font(.caption).foregroundStyle(.red)
                }
                Button("Show Welcome Again") {
                    model.prepareForWindow()
                    openWindow(id: WindowID.welcome)
                }
            }
        }
        .settingsPage(height: 600)
        .onAppear {
            loginState = LoginItem.state
            model.pollPermissions()
        }
    }
}
