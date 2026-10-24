import AppKit
import SwiftUI

/// The floating "Pairing Request" panel (DESIGN §4.7): above other windows,
/// on every Space and over full-screen apps. Esc closes it without deciding.
@MainActor
final class ApprovalPanelController {
    private var panel: NSPanel?

    func show(model: AppModel) {
        let panel = self.panel ?? make(model: model)
        self.panel = panel
        if !panel.isVisible { panel.center() }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.close()
    }

    private func make(model: AppModel) -> NSPanel {
        let panel = EscapablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 200),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: true)
        panel.title = String(localized: "Pairing Request")
        panel.identifier = NSUserInterfaceItemIdentifier("approval")
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        let controller = NSHostingController(rootView: ApprovalPanelView().environment(model))
        controller.sizingOptions = [.preferredContentSize]
        panel.contentViewController = controller
        return panel
    }

    private final class EscapablePanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override func cancelOperation(_ sender: Any?) { close() }
    }
}

struct ApprovalPanelView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("A phone wants to control this Mac")
                .font(.headline)
            Text("Allow it only if it's yours. It will be able to move the pointer, type and use the deck.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(model.approvals) { request in
                ApprovalRow(request: request, isDefault: request.id == model.approvals.first?.id)
            }
            if model.notificationStatus == .notDetermined {
                HStack {
                    Text("Get these requests as notifications instead.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Button("Use Notifications…") { model.requestNotifications() }
                }
            }
        }
        .padding(18)
        .padding(.top, 10)
        .frame(width: 380, alignment: .leading)
    }
}
