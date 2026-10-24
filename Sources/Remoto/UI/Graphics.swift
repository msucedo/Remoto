import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// The menu bar symbol: a phone with a pointer, drawn as a template image so
/// it follows the menu bar's appearance (DESIGN §6.2.3).
@MainActor
enum StatusIcon {
    private static var cache: [AppModel.MenuIcon: NSImage] = [:]

    static func image(_ state: AppModel.MenuIcon) -> NSImage {
        if let image = cache[state] { return image }
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            draw(state)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = AppInfo.name
        cache[state] = image
        return image
    }

    private static func draw(_ state: AppModel.MenuIcon) {
        NSColor.black.setFill()
        NSColor.black.setStroke()
        let body = NSRect(x: 4.25, y: 1.25, width: 9.5, height: 15.5)
        let outline = NSBezierPath(roundedRect: body, xRadius: 2.4, yRadius: 2.4)
        outline.lineWidth = 1.5

        switch state {
        case .connected:
            outline.fill()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            pointer(at: NSPoint(x: 7, y: 12.6)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
        case .paused:
            outline.stroke()
            NSBezierPath(roundedRect: NSRect(x: 6.9, y: 5.5, width: 1.6, height: 7), xRadius: 0.6, yRadius: 0.6).fill()
            NSBezierPath(roundedRect: NSRect(x: 9.5, y: 5.5, width: 1.6, height: 7), xRadius: 0.6, yRadius: 0.6).fill()
        case .idle, .request:
            outline.stroke()
            pointer(at: NSPoint(x: 7, y: 12.6)).fill()
        }

        if state == .request {
            // A badge: clear a ring, then fill the dot.
            let badge = NSRect(x: 11, y: 11, width: 7, height: 7)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: badge.insetBy(dx: -1.4, dy: -1.4)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSBezierPath(ovalIn: badge).fill()
        }
    }

    /// A small arrow pointer with its tip at `tip`.
    private static func pointer(at tip: NSPoint) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: tip)
        path.line(to: NSPoint(x: tip.x, y: tip.y - 7.4))
        path.line(to: NSPoint(x: tip.x + 1.8, y: tip.y - 5.6))
        path.line(to: NSPoint(x: tip.x + 3.1, y: tip.y - 8.2))
        path.line(to: NSPoint(x: tip.x + 4.4, y: tip.y - 7.6))
        path.line(to: NSPoint(x: tip.x + 3.1, y: tip.y - 5.0))
        path.line(to: NSPoint(x: tip.x + 5.4, y: tip.y - 4.9))
        path.close()
        path.lineJoinStyle = .round
        return path
    }
}

/// QR codes with medium error correction, one pixel per module (scale them
/// up with `.interpolation(.none)` for crisp modules).
@MainActor
enum QRCode {
    private static let context = CIContext(options: [.useSoftwareRenderer: false])
    private static var cache: [String: CGImage] = [:]

    static func image(for text: String) -> CGImage? {
        if let image = cache[text] { return image }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
            let image = context.createCGImage(output, from: output.extent)
        else { return nil }
        if cache.count > 16 { cache.removeAll() }
        cache[text] = image
        return image
    }
}

/// A QR code on a white plate, white in dark mode too (DESIGN §4.3).
struct QRCodeView: View {
    let text: String
    let size: CGFloat
    var label: LocalizedStringKey = "Pairing QR code"

    var body: some View {
        Group {
            if let image = QRCode.image(for: text) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(1, contentMode: .fit)
            } else {
                Image(systemName: "qrcode")
                    .resizable()
                    .aspectRatio(1, contentMode: .fit)
                    .foregroundStyle(.black.opacity(0.4))
            }
        }
        .frame(width: size, height: size)
        .padding(10)
        .background(.white, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement()
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(.isImage)
    }
}
