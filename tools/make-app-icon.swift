#!/usr/bin/env swift
// Regenerate Resources/AppIcon.icns from the standard macOS keyboard symbol.
// Run from the repository root: swift tools/make-app-icon.swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
let iconset = work.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }

guard let symbol = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)?
    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 128, weight: .regular)) else {
    fatalError("The system keyboard symbol is unavailable")
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels,
            pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        context.imageInterpolation = .high

        // A neutral macOS-style plate keeps the standard glyph legible in both
        // light and dark Finder backgrounds, without adding a custom logo.
        let plate = NSBezierPath(roundedRect: NSRect(x: 48, y: 48, width: 928, height: 928),
                                 xRadius: 208, yRadius: 208)
        NSColor(srgbRed: 0.94, green: 0.95, blue: 0.96, alpha: 1).setFill()
        plate.fill()
        NSColor(srgbRed: 0.80, green: 0.82, blue: 0.84, alpha: 1).setStroke()
        plate.lineWidth = 4
        plate.stroke()

        let width: CGFloat = 760
        let height = width * symbol.size.height / symbol.size.width
        let rect = NSRect(x: (1024 - width) / 2, y: (1024 - height) / 2,
                          width: width, height: height)
        context.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
        symbol.draw(in: rect)
        NSColor(srgbRed: 0.17, green: 0.19, blue: 0.21, alpha: 1).setFill()
        rect.fill(using: .sourceIn)
        context.cgContext.endTransparencyLayer()
        NSGraphicsContext.restoreGraphicsState()

        let suffix = scale == 2 ? "@2x" : ""
        let output = iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: output)
    }
}

let converter = Process()
converter.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
converter.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try converter.run()
converter.waitUntilExit()
guard converter.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Generated Resources/AppIcon.icns (standard keyboard symbol)")
