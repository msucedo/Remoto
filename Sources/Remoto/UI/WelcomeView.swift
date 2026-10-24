import RemotoCore
import SwiftUI

/// First-run walkthrough in three steps (DESIGN §4.6), with one fixed height
/// and a step indicator (DESIGN §6.2.6).
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Group {
                    switch step {
                    case 0: intro
                    case 1: accessibility
                    default: connect
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(28)
            }
            Divider()
            HStack {
                if step > 0 {
                    Button("Back") { withAnimation { step -= 1 } }
                }
                Spacer()
                if step < 2 {
                    Button("Continue") { withAnimation { step += 1 } }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Done") {
                        model.finishWelcome()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .overlay {
                Text("Step \(step + 1) of 3")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        }
        .frame(width: 520, height: 640)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Your phone, as a remote for this Mac")
                .font(.title2.weight(.semibold))
            Text("\(AppInfo.name) lives in the menu bar. There's nothing to install on the phone: it opens in the browser.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 14) {
                feature("hand.point.up.left", "Trackpad and keyboard", "Move the pointer, scroll, click and type from the phone.")
                feature("square.grid.3x2", "Button deck", "Shortcuts, apps, links and text one tap away.")
                feature("play.circle", "Media and apps", "Play, pause, change volume and switch apps.")
                feature("mic", "Dictation", "Speak into the phone and the text appears on the Mac.")
            }
            .padding(.top, 4)
        }
    }

    private func feature(_ symbol: String, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var accessibility: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Allow control in Accessibility")
                .font(.title2.weight(.semibold))
            Text(
                "To move the pointer and type for you, macOS needs you to allow \(AppInfo.name) in Privacy & Security › Accessibility. \(AppInfo.name) only does what your paired phones ask, and never records what you type."
            )
            .fixedSize(horizontal: false, vertical: true)
            Text("You can do this later from the menu bar.")
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                if model.accessibilityTrusted {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Accessibility is on")
                } else {
                    Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                    Text("Not allowed yet")
                }
                Spacer()
                if !model.accessibilityTrusted {
                    Button("Open Accessibility Settings") { Permissions.requestAccessibility() }
                }
            }
            .padding(12)
            .background(.tertiary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .combine)
        }
    }

    private var connect: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect your phone")
                .font(.title2.weight(.semibold))
            PairingCard(style: .large)
                .frame(maxWidth: .infinity)
        }
    }
}

/// The pairing card on its own (DESIGN §4.3, large).
struct PairWindowView: View {
    var body: some View {
        PairingCard(style: .large)
            .padding(24)
            .frame(width: 420)
    }
}
