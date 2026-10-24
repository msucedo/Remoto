import AppKit
import SwiftUI

extension AppModel.Tone {
    var color: Color {
        switch self {
        case .green: .green
        case .orange: .orange
        case .gray: .secondary
        case .red: .red
        }
    }
}

/// An 8 pt status dot.
struct StatusDot: View {
    let tone: AppModel.Tone
    var body: some View {
        Circle().fill(tone.color).frame(width: 8, height: 8).accessibilityHidden(true)
    }
}

/// A notice row: colored symbol, wrapping text, actions underneath. Uses the
/// system's quaternary fill so it sits well on glass; the color stays on the
/// symbol (DESIGN §6.2.2).
struct Callout<Actions: View>: View {
    let symbol: String
    let tint: Color
    let text: Text
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .font(.callout)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                text.font(.callout).fixedSize(horizontal: false, vertical: true)
                actions
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

extension Callout where Actions == EmptyView {
    init(symbol: String, tint: Color, text: Text) {
        self.init(symbol: symbol, tint: tint, text: text) { EmptyView() }
    }
}

/// Permission row for settings: state icon, title, detail and, when missing, buttons.
struct PermissionRow<Buttons: View>: View {
    let title: Text
    let detail: Text
    let granted: Bool
    @ViewBuilder var buttons: Buttons

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
                .font(.title3)
                .accessibilityLabel(granted ? Text("Allowed") : Text("Not allowed"))
            VStack(alignment: .leading, spacing: 2) {
                title
                detail.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !granted {
                HStack { buttons }
            }
        }
    }
}

/// Reports whether the view's window is on screen, so cards that show the PIN
/// can tell the core (the menu bar window is hidden, not destroyed).
struct WindowVisibilityReader: NSViewRepresentable {
    let onChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
    }

    static func dismantleNSView(_ view: ReaderView, coordinator: ()) {
        view.stop()
    }

    final class ReaderView: NSView {
        var onChange: (@MainActor (Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var last: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeObservers()
            if let window {
                let center = NotificationCenter.default
                for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification] {
                    observers.append(
                        center.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                            let closing = note.name == NSWindow.willCloseNotification
                            MainActor.assumeIsolated { self?.evaluate(closing: closing) }
                        })
                }
            }
            evaluate(closing: false)
        }

        func stop() {
            removeObservers()
            report(false)
        }

        private func removeObservers() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
        }

        private func evaluate(closing: Bool) {
            guard let window, !closing else { return report(false) }
            report(window.isVisible && window.occlusionState.contains(.visible))
        }

        private func report(_ visible: Bool) {
            guard visible != last else { return }
            last = visible
            onChange?(visible)
        }
    }
}

extension View {
    /// Calls `action(true)` while the view is in a visible window, `false` otherwise.
    func onWindowVisibilityChange(_ action: @escaping @MainActor (Bool) -> Void) -> some View {
        background(WindowVisibilityReader(onChange: action).frame(width: 0, height: 0))
    }
}

/// "5 min ago" style relative times for UNIX seconds.
enum RelativeTime {
    static func string(unix: Int64) -> String {
        guard unix > 0 else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(unix))
        return date.formatted(.relative(presentation: .named))
    }
}
