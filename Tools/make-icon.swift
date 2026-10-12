#!/usr/bin/env swift
// Draws AppIcon.icns from scratch so the project has no binary assets checked in.
// Usage: swift Tools/make-icon.swift <output.icns>

import AppKit
import Foundation

_ = NSApplication.shared

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.icns>\n".utf8))
    exit(1)
}
let outputURL = URL(fileURLWithPath: arguments[1])

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    NSGraphicsContext.current?.imageInterpolation = .high

    // macOS icon grid: the squircle sits inset inside the canvas.
    let inset = size * 0.085
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = rect.width * 0.2237
    let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.13, green: 0.77, blue: 0.55, alpha: 1),
        NSColor(srgbRed: 0.05, green: 0.52, blue: 0.62, alpha: 1),
    ])
    gradient?.draw(in: squircle, angle: -90)

    // Subtle top highlight for depth.
    squircle.addClip()
    let highlight = NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.22),
        NSColor.white.withAlphaComponent(0.0),
    ])
    highlight?.draw(in: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: -90)

    let glyphSize = size * 0.46
    if let symbol = NSImage(systemSymbolName: "timer", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: glyphSize, weight: .medium)) {
        let tinted = NSImage(size: symbol.size)
        tinted.lockFocus()
        symbol.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        NSColor.white.set()
        NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
        tinted.unlockFocus()

        let origin = NSPoint(
            x: (size - tinted.size.width) / 2,
            y: (size - tinted.size.height) / 2
        )
        tinted.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
    } else {
        // Fallback glyph if the SF Symbol is unavailable.
        NSColor.white.set()
        let body = NSBezierPath(
            roundedRect: NSRect(x: size * 0.32, y: size * 0.26, width: size * 0.36, height: size * 0.46),
            xRadius: size * 0.05,
            yRadius: size * 0.05
        )
        body.fill()
    }

    return image
}

let iconsetURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("WorkTimerIcon-\(UUID().uuidString).iconset")
try? FileManager.default.removeItem(at: iconsetURL)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

// (pixel size, filename) pairs required by iconutil.
let variants: [(CGFloat, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

for (pixels, name) in variants {
    let image = drawIcon(size: pixels)
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("failed to render \(name)\n".utf8))
        exit(1)
    }
    try png.write(to: iconsetURL.appendingPathComponent(name))
}

try? FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
try process.run()
process.waitUntilExit()
try? FileManager.default.removeItem(at: iconsetURL)

guard process.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(process.terminationStatus)
}
print("icon written to \(outputURL.path)")
