// Generates Tape's app icon: Resources/AppIcon.icns (+ Resources/AppIcon.png).
//
//   swift scripts/make-icon.swift
//
// The mark: two tape reels joined by the tape, in ink on Onword's sand tile (same geometry as `TapeMark` in the app), on the macOS icon grid (824 pt rounded square on a 1024 canvas).
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.first.map { URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent().path } ?? ".")
let resources = root.appendingPathComponent("Resources")

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

/// Same geometry as `TapeMark.path` in the app.
func drawGlyph(in box: CGRect) {
    let s = box.width / 1024
    let path = NSBezierPath()
    path.windingRule = .evenOdd
    let r: CGFloat = 170 * s, hole: CGFloat = 58 * s, cy = box.midY + 40 * s
    for cx in [box.midX - 215 * s, box.midX + 215 * s] {
        path.appendOval(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
        path.appendOval(in: CGRect(x: cx - hole, y: cy - hole, width: 2 * hole, height: 2 * hole))
    }
    color(0x1A1A1A).setFill()
    path.fill()
    let bar: CGFloat = 44 * s
    NSBezierPath(roundedRect: CGRect(x: box.midX - 215 * s, y: cy - r - bar / 2 + 6 * s, width: 430 * s, height: bar),
                 xRadius: bar / 2, yRadius: bar / 2).fill()
}

func icon(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(size) / 1024
    NSGraphicsContext.current!.cgContext.scaleBy(x: scale, y: scale)

    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.20)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    color(0xEEEBE3).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0xFDFCF9), ending: color(0xECE8DE))!.draw(in: shape, angle: -90)
    color(0xDDD8CB).setStroke()
    shape.lineWidth = 2
    shape.stroke()

    drawGlyph(in: CGRect(x: 127, y: 107, width: 770, height: 770))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("TapeIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! icon(size: base * scale).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
try! icon(size: 1024).representation(using: .png, properties: [:])!.write(to: resources.appendingPathComponent("AppIcon.png"))
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns and Resources/AppIcon.png" : "iconutil failed")
