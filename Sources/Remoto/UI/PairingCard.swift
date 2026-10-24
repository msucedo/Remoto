import AppKit
import RemotoCore
import SwiftUI

/// QR, PIN, countdown and addresses (DESIGN §4.3). While it is on screen the
/// Mac accepts the PIN.
struct PairingCard: View {
    enum Style { case compact, large }

    @Environment(AppModel.self) private var model
    let style: Style
    @State private var shown = false

    private var large: Bool { style == .large }

    var body: some View {
        VStack(alignment: large ? .center : .leading, spacing: 12) {
            if large {
                VStack(spacing: 4) {
                    Text("Scan it with your phone's camera")
                        .font(.title3.weight(.semibold))
                    Text("Your phone needs to be on the same network as this Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
            }
            if !model.isRunning {
                Text("The server isn't running")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: large ? .center : .leading)
            } else if let info = model.pairing {
                details(info)
            } else {
                Text("Loading…")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: large ? .center : .leading)
            }
        }
        .onWindowVisibilityChange { visible in
            guard visible != shown else { return }
            shown = visible
            model.pinCard(visible: visible)
        }
    }

    @ViewBuilder
    private func details(_ info: PairingInfo) -> some View {
        HStack {
            Spacer(minLength: 0)
            QRCodeView(text: info.link, size: large ? 240 : 170)
            Spacer(minLength: 0)
        }

        if model.prefs.allowPin {
            VStack(alignment: large ? .center : .leading, spacing: 2) {
                Text("PIN")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(verbatim: Self.grouped(info.pin))
                    .font(.system(size: large ? 30 : 22, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                    .accessibilityLabel(Text("PIN \(info.pin.map(String.init).joined(separator: " "))"))
            }
            .frame(maxWidth: .infinity, alignment: large ? .center : .leading)
        }

        HStack(spacing: 8) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                countdown(at: context.date)
            }
            Spacer(minLength: 4)
            Button("New Code") { model.renewPairing() }
        }

        addresses(info)
    }

    private func countdown(at now: Date) -> some View {
        let remaining = Int((model.pairingExpiresAt?.timeIntervalSince(now) ?? 0).rounded(.up))
        return Group {
            if remaining > 0 {
                let time = Duration.seconds(remaining).formatted(.time(pattern: .minuteSecond))
                Text("The code changes in \(time)")
            } else {
                Text("Refreshing…")
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func addresses(_ info: PairingInfo) -> some View {
        let vpn = Set(info.vpnAddresses)
        let lan = info.addresses.filter { !vpn.contains($0) }
        let linkUsesIP = info.addresses.contains { info.address.contains($0) }
        let rows = [info.address] + ((large || !linkUsesIP) ? lan.map { Self.url(ip: $0, port: info.port) } : [])
        VStack(alignment: .leading, spacing: 4) {
            Text("Or open this address on your phone:")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(Array(Self.unique(rows).enumerated()), id: \.offset) { _, address in
                AddressRow(address: address)
            }
            if !vpn.isEmpty {
                let list = info.vpnAddresses.map { Self.url(ip: $0, port: info.port) }.joined(separator: ", ")
                Text("Over VPN: \(list)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func grouped(_ pin: String) -> String {
        guard pin.count == 6 else { return pin }
        return "\(pin.prefix(3)) \(pin.suffix(3))"
    }

    static func url(ip: String, port: UInt16) -> String {
        let host = ip.contains(":") ? "[\(ip)]" : ip
        return "http://\(host):\(port)"
    }

    private static func unique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }
}

/// A selectable address with a copy button.
struct AddressRow: View {
    let address: String

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: address)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(address, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help(Text("Copy address"))
            .accessibilityLabel(Text("Copy address"))
        }
    }
}
