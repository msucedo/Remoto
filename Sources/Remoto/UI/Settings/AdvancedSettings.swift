import AppKit
import RemotoCore
import SwiftUI

struct AdvancedSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var prefs = model.prefs
        Form {
            Section("App Folders") {
                Text(
                    "Apps in Applications, Utilities and your home Applications folder are listed on the phone. Add other folders, like an external drive, here."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                ForEach(prefs.appFolders, id: \.self) { path in
                    HStack {
                        Image(systemName: "folder").accessibilityHidden(true)
                        Text(verbatim: path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            model.removeAppFolder(path)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help(Text("Remove folder"))
                        .accessibilityLabel(Text("Remove \(path)"))
                    }
                }
                Button("Add Folder…", action: addFolder)
            }

            Section("Network") {
                Toggle("Accept connections forwarded by a local proxy", isOn: $prefs.allowLocalProxy)
                    .onChange(of: prefs.allowLocalProxy) { model.applyConfig() }
                Button("Restart Server") { model.restartServer() }
            }

            Section("Diagnostics") {
                Picker("Log level", selection: $prefs.logFilter) {
                    Text("Errors").tag(LogLevel.error)
                    Text("Warnings").tag(LogLevel.warning)
                    Text("Info").tag(LogLevel.info)
                    Text("Debug").tag(LogLevel.debug)
                }
                .onChange(of: prefs.logFilter) { RemotoHost.initLogging(prefs.logFilter.rawValue) }
                Text("Logs go to the system log. They never include what you type or copy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Show Data Folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppInfo.dataDirectory])
                }
            }
        }
        .settingsPage(height: 540)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Add Folder")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.addAppFolder(url)
    }
}

struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)
            Text(verbatim: AppInfo.name)
                .font(.title.weight(.semibold))
            Text("Version \(AppInfo.version) (\(AppInfo.build))")
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("Use your phone as a trackpad, keyboard, button deck, media remote and dictation mic for this Mac, over your local network.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)
            Text("Open source under the MIT License.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Link("Source Code", destination: AppInfo.repositoryURL)
                Link("License", destination: AppInfo.licenseURL)
                Link("Report an Issue", destination: AppInfo.issuesURL)
            }
            .padding(.top, 4)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
    }
}
