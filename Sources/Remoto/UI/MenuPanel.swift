import AppKit
import RemotoCore
import SwiftUI

/// The window under the menu bar icon (DESIGN §4.2).
struct MenuPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var pairExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            ForEach(model.approvals) { request in
                ApprovalRow(request: request, isDefault: request.id == model.approvals.first?.id)
            }

            if model.isRunning && !model.accessibilityTrusted {
                Callout(
                    symbol: "exclamationmark.shield.fill", tint: .orange,
                    text: Text("Phones can't control this Mac until you allow \(AppInfo.name) in Accessibility settings.")
                ) {
                    Button("Open Privacy Settings") { Permissions.requestAccessibility() }
                }
            }

            if !model.webClientBundled {
                Callout(
                    symbol: "exclamationmark.triangle.fill", tint: .yellow,
                    text: Text("This build doesn't include the phone app. Build the web client and rebuild."))
            }

            if let notice = model.notice {
                Callout(symbol: "info.circle.fill", tint: .blue, text: Text(verbatim: notice.text)) {
                    Button("Dismiss") { model.notice = nil }
                }
            }

            if !model.connected.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Connected")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(model.connected) { device in
                        HStack(spacing: 6) {
                            Image(systemName: "iphone").accessibilityHidden(true)
                            Text(verbatim: device.name).lineLimit(1)
                            Spacer(minLength: 4)
                            if device.secure {
                                Image(systemName: "lock.fill")
                                    .foregroundStyle(.secondary)
                                    .help(Text("Encrypted"))
                                    .accessibilityLabel(Text("Encrypted"))
                            }
                        }
                        .font(.callout)
                        .accessibilityElement(children: .combine)
                    }
                }
            }

            if model.isRunning {
                DisclosureGroup(isExpanded: $pairExpanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        PairingCard(style: .compact)
                        Button("Show in a Window…") { open(window: WindowID.pair) }
                    }
                    .padding(.top, 8)
                } label: {
                    Text(model.trusted.isEmpty && model.connected.isEmpty ? "Pair your phone" : "Pair another phone")
                        .font(.callout.weight(.semibold))
                }
            }

            Divider()

            Toggle(
                "Allow phones to control this Mac",
                isOn: Binding(get: { model.controlAllowed }, set: { model.setControlAllowed($0) })
            )
            .toggleStyle(.switch)
            .disabled(!model.isRunning)

            HStack {
                Button("Settings…") {
                    dismiss()
                    model.prepareForWindow()
                    openSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
                if case .failed = model.server {
                    Button("Try Again") { model.startServer() }
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
        .onWindowVisibilityChange { visible in
            guard visible else { return }
            model.refreshDevices()
            model.refreshPairing()
            model.pollPermissions()
            if model.trusted.isEmpty && model.connected.isEmpty { pairExpanded = true }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            StatusDot(tone: model.status.tone)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: AppInfo.name).font(.headline)
                Text(verbatim: model.status.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func open(window id: String) {
        dismiss()
        model.prepareForWindow()
        openWindow(id: id)
    }
}

/// One pending approval: device, model and address, with Deny and Allow.
struct ApprovalRow: View {
    @Environment(AppModel.self) private var model
    let request: ApprovalRequest
    let isDefault: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "iphone.radiowaves.left.and.right")
                .font(.title2)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: ApprovalNotifier.displayName(request))
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(verbatim: [request.model, request.address].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Button("Deny") { model.respond(to: request.id, allow: false) }
            if isDefault {
                Button("Allow") { model.respond(to: request.id, allow: true) }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Allow") { model.respond(to: request.id, allow: true) }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }
}

enum WindowID {
    static let welcome = "welcome"
    static let pair = "pair"
}
