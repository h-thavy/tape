// Generates Tape's app icon: Resources/AppIcon.icns (+ Resources/AppIcon.png).
//
//   swift scripts/make-icon.swift
//
// The mark: a cute cassette (its reels are its eyes), in ink on Onword's sand tile, its window in Onword's
// lavender. Same geometry as
// `TapeMark` in the app (which also draws the menu bar icon), on the macOS icon grid (824 pt rounded square
// on a 1024 canvas).
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.first.map { URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent().path } ?? ".")
let resources = root.appendingPathComponent("Resources")

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

/// The cassette in a 1024-unit box (y-up), drawn as a little character: a soft rounded body with its window
/// and the notch cut out, the window, two reels for eyes (with their shine), a smile, and blush.
struct Mark {
    var body = CGMutablePath(), window = CGMutablePath(), eyes = CGMutablePath(), shine = CGMutablePath()
    var smile = CGMutablePath(), blush = CGMutablePath()
    var smileWidth: CGFloat = 0
}

func cassette(in box: CGRect) -> Mark {
    let s = box.width / 1024
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: box.minX + x * s, y: box.minY + y * s) }
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(origin: p(x, y), size: CGSize(width: w * s, height: h * s)) }
    var m = Mark()
    m.window.addRoundedRect(in: r(232, 436, 560, 250), cornerWidth: 96 * s, cornerHeight: 96 * s)
    m.body.addRoundedRect(in: r(112, 262, 800, 540), cornerWidth: 170 * s, cornerHeight: 170 * s)
    m.body.addPath(m.window)
    // The notch along the bottom edge, rounded like the rest.
    m.body.move(to: p(338, 262))
    m.body.addCurve(to: p(392, 332), control1: p(358, 262), control2: p(372, 332))
    m.body.addLine(to: p(632, 332))
    m.body.addCurve(to: p(686, 262), control1: p(652, 332), control2: p(666, 262))
    m.body.closeSubpath()
    // Eyes: the reels, big and round, each with a large and a small shine.
    for cx: CGFloat in [382, 642] {
        m.eyes.addEllipse(in: r(cx - 78, 572 - 78, 156, 156))
        m.shine.addEllipse(in: r(cx - 46, 582, 46, 46))
        m.shine.addEllipse(in: r(cx + 18, 524, 22, 22))
    }
    // A small smile between them.
    m.smile.move(to: p(482, 512))
    m.smile.addQuadCurve(to: p(542, 512), control: p(512, 478))
    m.smileWidth = 20 * s
    // Blush on the cheeks, on the body below the window.
    for cx: CGFloat in [262, 762] { m.blush.addEllipse(in: r(cx - 54, 370, 108, 52)) }
    return m
}

func icon(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let cg = NSGraphicsContext.current!.cgContext
    let scale = CGFloat(size) / 1024
    cg.scaleBy(x: scale, y: scale)

    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
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

    // The cassette, a little smaller than the tile's grid so it breathes.
    let mark = cassette(in: CGRect(x: 152, y: 130, width: 720, height: 720))
    cg.addPath(mark.window); cg.setFillColor(color(0xF4E1FF).cgColor); cg.fillPath()
    cg.addPath(mark.body); cg.setFillColor(color(0x1A1A1A).cgColor); cg.fillPath(using: .evenOdd)
    cg.addPath(mark.blush); cg.setFillColor(color(0xFF8FB1).withAlphaComponent(0.85).cgColor); cg.fillPath()
    cg.addPath(mark.eyes); cg.setFillColor(color(0x1A1A1A).cgColor); cg.fillPath()
    cg.addPath(mark.shine); cg.setFillColor(color(0xFFFFFF).cgColor); cg.fillPath()
    cg.addPath(mark.smile); cg.setStrokeColor(color(0x1A1A1A).cgColor); cg.setLineWidth(mark.smileWidth); cg.setLineCap(.round); cg.strokePath()
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
