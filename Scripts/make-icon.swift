// Renders the app icon and writes Resources/AppIcon.icns.
// Usage: swift Scripts/make-icon.swift   (run from the repo root)
import AppKit

func renderIcon(size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = CGFloat(size)
    // Full-bleed opaque square. macOS 26 applies its own rounded mask to icons like this;
    // an icon that draws its own inset rounded shape gets shrunk onto a grey backing plate instead.
    let gradient = NSGradient(
        starting: NSColor(srgbRed: 0.33, green: 0.42, blue: 0.98, alpha: 1),
        ending: NSColor(srgbRed: 0.16, green: 0.18, blue: 0.55, alpha: 1))!
    gradient.draw(in: NSRect(x: 0, y: 0, width: s, height: s), angle: -90)

    // White speaker glyph, centred.
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.48, weight: .semibold)
    if let symbol = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let glyphSize = symbol.size
        let tinted = NSImage(size: glyphSize)
        tinted.lockFocus()
        symbol.draw(in: NSRect(origin: .zero, size: glyphSize))
        NSColor.white.set()
        NSRect(origin: .zero, size: glyphSize).fill(using: .sourceAtop)
        tinted.unlockFocus()
        tinted.draw(in: NSRect(
            x: (s - glyphSize.width) / 2, y: (s - glyphSize.height) / 2,
            width: glyphSize.width, height: glyphSize.height))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: iconset) }

// Deliberately no 16pt or 32pt bitmaps. On macOS 26, when those are present the system uses them
// for small sizes on non-Retina displays and draws them on a light backing plate; without them it
// scales the large artwork down itself and applies its normal mask.
for points in [128, 256, 512] {
    try renderIcon(size: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try renderIcon(size: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

try fm.createDirectory(atPath: "Resources", withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }

// Also keep a PNG preview for the README.
try renderIcon(size: 256).write(to: URL(fileURLWithPath: "Resources/AppIcon.png"))
print("Wrote Resources/AppIcon.icns")
