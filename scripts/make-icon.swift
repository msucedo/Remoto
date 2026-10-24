#!/usr/bin/env swift
// Draws the app icon with CoreGraphics and writes Support/AppIcon.icns.
//
//   swift scripts/make-icon.swift
//
// The design: the brand gradient (#3aa7e0 → #5b6cf0) on the macOS icon
// rounded square, with a white phone outline and a pointer inside it.

import AppKit
import CoreGraphics
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let output = root.appending(path: "Support/AppIcon.icns")
let work = FileManager.default.temporaryDirectory.appending(path: "remoto-icon-\(getpid())")
let iconset = work.appending(path: "AppIcon.iconset")
try? FileManager.default.removeItem(at: work)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Draws the icon on a 1024-unit canvas scaled to `pixels`.
func render(pixels: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    // Body: 824 × 824 centered, like the system icon grid, with a soft shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, alpha: 0.28))
    context.addPath(shape)
    context.setFillColor(color(0x4a8be8))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(shape)
    context.clip()
    let gradient = CGGradient(
        colorsSpace: space, colors: [color(0x3aa7e0), color(0x5b6cf0)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(
        gradient, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])
    // A faint top highlight.
    let shine = CGGradient(
        colorsSpace: space, colors: [color(0xffffff, alpha: 0.18), color(0xffffff, alpha: 0)] as CFArray,
        locations: [0, 1])!
    context.drawLinearGradient(
        shine, start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: 560), options: [])
    context.restoreGState()

    // Phone outline.
    let phone = CGRect(x: 512 - 170, y: 512 - 262, width: 340, height: 524)
    context.setStrokeColor(color(0xffffff))
    context.setLineWidth(42)
    context.addPath(CGPath(roundedRect: phone, cornerWidth: 70, cornerHeight: 70, transform: nil))
    context.strokePath()

    // Pointer, tip up and to the left, inside the screen.
    let tip = CGPoint(x: 452, y: 652)
    let points: [CGPoint] = [
        tip,
        CGPoint(x: tip.x, y: tip.y - 238),
        CGPoint(x: tip.x + 58, y: tip.y - 182),
        CGPoint(x: tip.x + 98, y: tip.y - 268),
        CGPoint(x: tip.x + 140, y: tip.y - 250),
        CGPoint(x: tip.x + 100, y: tip.y - 164),
        CGPoint(x: tip.x + 176, y: tip.y - 160),
    ]
    let pointer = CGMutablePath()
    pointer.addLines(between: points)
    pointer.closeSubpath()
    context.setFillColor(color(0xffffff))
    context.setLineJoin(.round)
    context.setLineWidth(18)
    context.addPath(pointer)
    context.drawPath(using: .fillStroke)

    return context.makeImage()!
}

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, pixels) in sizes {
    let rep = NSBitmapImageRep(cgImage: render(pixels: pixels))
    guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("PNG encoding failed") }
    try png.write(to: iconset.appending(path: "\(name).png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
try? FileManager.default.removeItem(at: work)
print("wrote \(output.path)")
