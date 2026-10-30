// Generates Tape's app icon: Resources/AppIcon.icns (+ Resources/AppIcon.png).
//
//   swift scripts/make-icon.swift
//
// The mark: a cassette, in ink on Onword's sand tile, its window in Onword's lavender. Same geometry as
// `TapeMark` in the app (which also draws the menu bar icon), on the macOS icon grid (824 pt rounded square
// on a 1024 canvas).
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.first.map { URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent().path } ?? ".")
let resources = root.appendingPathComponent("Resources")

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

/// The cassette in a 1024-unit box (y-up): the body with its window and the notch cut out (fill even-odd), the
/// window, the two reels (rings, even-odd) and the teeth of their hubs.
struct Mark {
    var body = CGMutablePath(), window = CGMutablePath(), reels = CGMutablePath(), teeth = CGMutablePath()
}

func cassette(in box: CGRect) -> Mark {
    let s = box.width / 1024
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: box.minX + x * s, y: box.minY + y * s) }
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(origin: p(x, y), size: CGSize(width: w * s, height: h * s)) }
    var m = Mark()
    m.window.addRoundedRect(in: r(236, 472, 552, 196), cornerWidth: 44 * s, cornerHeight: 44 * s)
    m.body.addRoundedRect(in: r(104, 288, 816, 488), cornerWidth: 76 * s, cornerHeight: 76 * s)
    m.body.addPath(m.window)
    // The notch along the bottom edge, where the tape meets the head.
    m.body.move(to: p(316, 288)); m.body.addLine(to: p(360, 356)); m.body.addLine(to: p(664, 356)); m.body.addLine(to: p(708, 288))
    m.body.closeSubpath()
    let cy: CGFloat = 570
    for cx: CGFloat in [374, 650] {
        m.reels.addEllipse(in: r(cx - 66, cy - 66, 132, 132))
        m.reels.addEllipse(in: r(cx - 36, cy - 36, 72, 72))
        // Six teeth around the hub, pointing in.
        for k in 0..<6 {
            let angle = CGFloat(k) * .pi / 3 + .pi / 6
            let tooth = CGRect(x: -7 * s, y: 18 * s, width: 14 * s, height: 22 * s)
            var t = CGAffineTransform(translationX: p(cx, cy).x, y: p(cx, cy).y).rotated(by: angle)
            m.teeth.addPath(CGPath(roundedRect: tooth, cornerWidth: 4 * s, cornerHeight: 4 * s, transform: &t))
        }
    }
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
    let mark = cassette(in: CGRect(x: 152, y: 140, width: 720, height: 720))
    cg.addPath(mark.window); cg.setFillColor(color(0xF4E1FF).cgColor); cg.fillPath()
    cg.addPath(mark.body); cg.setFillColor(color(0x1A1A1A).cgColor); cg.fillPath(using: .evenOdd)
    cg.addPath(mark.reels); cg.fillPath(using: .evenOdd)
    cg.addPath(mark.teeth); cg.fillPath()
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
