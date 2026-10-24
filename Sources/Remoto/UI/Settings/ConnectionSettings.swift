import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ConnectionSettings: View {
    @Environment(AppModel.self) private var model
    @State private var port: Int = Preferences.defaultPort
    @State private var customHost = ""
    @State private var exportError: String?

    private var portValid: Bool { Preferences.isValidPort(port) }

    var body: some View {
        @Bindable var prefs = model.prefs
        Form {
            Section("Server") {
                LabeledContent("Port") {
                    HStack(spacing: 8) {
                        TextField("Port", value: $port, format: .number.grouping(.never))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                            .onSubmit(applyPort)
                        Stepper("Port", value: $port, in: 1024...65535)
                            .labelsHidden()
                        Button("Apply", action: applyPort)
                            .disabled(!portValid || port == prefs.port)
                    }
                }
                if !portValid {
                    Text("Use a port from 1024 to 65535.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if let running = model.runningPort {
                    LabeledContent("Status") {
                        Text("Listening on \(Int(running))").monospacedDigit()
                    }
                    if model.preferredPortTaken {
                        Text("Port \(prefs.port) was in use, so another one was picked.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Pairing Link") {
                Picker("QR address", selection: $prefs.linkHostMode) {
                    Text("Name (.local)").tag(LinkHostMode.hostName)
                    Text("IP address").tag(LinkHostMode.ipAddress)
                    Text("Custom").tag(LinkHostMode.custom)
                }
                .onChange(of: prefs.linkHostMode) { model.applyConfig() }
                if prefs.linkHostMode == .custom {
                    TextField("Address", text: $customHost, prompt: Text(verbatim: "mac.example.net:8740"))
                        .onSubmit { commitCustomHost() }
                        .onChange(of: customHost) {
                            prefs.customHost = customHost
                        }
                        .task(id: customHost) {
                            try? await Task.sleep(for: .milliseconds(700))
                            if !Task.isCancelled { model.applyConfig() }
                        }
                }
                Toggle("Accept a 6-digit PIN", isOn: $prefs.allowPin)
                    .onChange(of: prefs.allowPin) { model.applyConfig() }
                Toggle("Ask on this Mac when a phone connects without a code", isOn: $prefs.allowApproval)
                    .onChange(of: prefs.allowApproval) { model.applyConfig() }
            }

            Section("Encrypted Connection") {
                Text(
                    "Install this Mac's certificate on the phone to use an encrypted (https) connection. Dictation needs it."
                )
                .fixedSize(horizontal: false, vertical: true)
                if let info = model.pairing, model.isRunning {
                    HStack(alignment: .top, spacing: 14) {
                        QRCodeView(
                            text: info.address + AppInfo.certificatePath, size: 110, label: "Certificate download QR code")
                        VStack(alignment: .leading, spacing: 6) {
                            Text("1. Scan the code with the phone and download the certificate.")
                            Text("2. iPhone: install it in Settings › General › VPN & Device Management, then turn on full trust in General › About › Certificate Trust Settings.")
                            Text("3. Android: install it in Settings › Security › Encryption & credentials › Install a certificate › CA certificate.")
                        }
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    if !info.caFingerprint.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("SHA-256 fingerprint").font(.caption).foregroundStyle(.secondary)
                            Text(verbatim: info.caFingerprint)
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                HStack {
                    Button("Export Certificate…", action: exportCertificate)
                    if let exportError {
                        Text(verbatim: exportError).font(.caption).foregroundStyle(.red)
                    }
                }
            }
        }
        .settingsPage(height: 700)
        .onAppear {
            port = model.prefs.port
            customHost = model.prefs.customHost
            model.refreshPairing()
        }
        .onDisappear(perform: commitCustomHost)
    }

    private func applyPort() {
        guard portValid, port != model.prefs.port else { return }
        model.applyPort(port)
    }

    private func commitCustomHost() {
        guard model.prefs.linkHostMode == .custom else { return }
        model.prefs.customHost = customHost
        model.applyConfig()
    }

    private func exportCertificate() {
        let data = model.certificate()
        guard !data.isEmpty else {
            exportError = String(localized: "There's no certificate yet. Start the server first.")
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(AppInfo.name) CA.cer"
        panel.allowedContentTypes = [UTType(filenameExtension: "cer") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            exportError = nil
        } catch {
            exportError = error.localizedDescription
        }
    }
}
