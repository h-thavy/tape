import AppKit
import CoreText
import SwiftUI

/// Tape's look: black and white chrome (ink on white, white on near-black in dark mode, greys for what's
/// secondary), with colour kept for meaning: one colour per speaker, green/amber/red for a recap's status, and
/// red for a recording in progress. Every text colour reaches 4.5:1 against the surfaces it sits on (WCAG AA)
/// and every speaker colour 3:1; scripts/contrast.py checks them. Type is Geist, with Geist Mono for times.
enum Theme {
    // MARK: Colours

    /// The window and the reader.
    static let background = dynamic(light: 0xFFFFFF, dark: 0x0E0E0E)
    /// The library column.
    static let sidebar = dynamic(light: 0xFAFAFA, dark: 0x141414)
    /// Cards and the selected row.
    static let raised = dynamic(light: 0xFFFFFF, dark: 0x1B1B1B)
    /// Chips, fields, the search box.
    static let fill = dynamic(light: 0xF2F2F2, dark: 0x232323)
    /// Hairlines.
    static let line = dynamic(light: 0xEAEAEA, dark: 0x2A2A2A)
    static let ink = dynamic(light: 0x0A0A0A, dark: 0xF5F5F5)
    /// Body text.
    static let body = dynamic(light: 0x333333, dark: 0xD4D4D4)
    static let ink2 = dynamic(light: 0x4A4A4A, dark: 0xB8B8B8)
    static let ink3 = dynamic(light: 0x6E6E6E, dark: 0x8F8F8F)
    /// Text on an ink background (the prominent buttons).
    static let onInk = dynamic(light: 0xFFFFFF, dark: 0x0A0A0A)
    /// A recording in progress (the dot; 3.5:1 on white, 4.6:1 on the black island).
    static let recording = Color(hex: 0xFF3B30)
    /// Statuses, as text: recap ready, being made, failed.
    static let ready = dynamic(light: 0x137333, dark: 0x4ADE80)
    static let working = dynamic(light: 0xA04A06, dark: 0xFBBF24)
    static let failed = dynamic(light: 0xC81E1E, dark: 0xF87171)
    /// Switches and selection.
    static let accent = dynamic(light: 0x0A0A0A, dark: 0x9A9A9A)

    /// A colour per speaker, in order of talk time; everyone after the fourth shares the slate.
    static func speaker(_ index: Int) -> Color {
        speakers[min(index, speakers.count - 1)]
    }
    private static let speakers = zip(speakerHex.light, speakerHex.dark).map { dynamic(light: $0, dark: $1) }
    static let speakerHex: (light: [UInt32], dark: [UInt32]) = (
        [0x4F46E5, 0x0F8A7E, 0xC2610C, 0xD02670, 0x64748B],
        [0xA5B4FC, 0x5EEAD4, 0xFCD34D, 0xF9A8D4, 0x94A3B8]
    )
    static let namedSpeakers = 4

    /// On the black notch island (the same in light and dark mode).
    enum Island {
        static let text = Color(hex: 0xFAFAFA)
        static let text2 = Color(hex: 0x9A9A9A)
        static let text3 = Color(hex: 0x8A8A8A)
        static let tile = Color.white.opacity(0.09)
        static let quiet = Color.white.opacity(0.12)
        static func speaker(_ index: Int) -> Color {
            Color(hex: Theme.speakerHex.dark[min(index, Theme.speakerHex.dark.count - 1)])
        }
    }

    // MARK: Type

    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Fonts.registered ? .custom("Geist", size: size).weight(weight) : .system(size: size, weight: weight)
    }

    /// Titles.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font { sans(size, weight) }

    /// Times and counters.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Fonts.registered ? .custom("Geist Mono", size: size).weight(weight) : .system(size: size, weight: weight, design: .monospaced)
    }

    // MARK: Shape

    static let radius: CGFloat = 8
    static let radiusMedium: CGFloat = 11
    static let radiusLarge: CGFloat = 14

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

/// Geist and Geist Mono, from the app's Resources/Fonts (registered for this process only).
enum Fonts {
    @MainActor static func register() {
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        var count = 0
        for file in files where file.pathExtension == "ttf" {
            if CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil) { count += 1 }
        }
        registered = count > 0
    }

    /// Set once at launch, before any view is drawn.
    nonisolated(unsafe) static var registered = false
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: - Mark

/// Tape's mark: a cassette. Same geometry as scripts/make-icon.swift, which renders the app icon.
enum TapeMark {
    struct Shape {
        /// The body with its window and the notch cut out (fill even-odd).
        var body = CGMutablePath()
        var window = CGMutablePath()
        /// The reels as rings (fill even-odd).
        var reels = CGMutablePath()
        /// The reels' centres, for turning their teeth.
        var hubs: [CGPoint] = []
        var scale: CGFloat = 1
    }

    /// The cassette in `box` (a square, y-up).
    static func shape(in box: CGRect) -> Shape {
        let s = box.width / 1024
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: box.minX + x * s, y: box.minY + y * s) }
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(origin: p(x, y), size: CGSize(width: w * s, height: h * s))
        }
        var m = Shape()
        m.scale = s
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
            m.hubs.append(p(cx, cy))
        }
        return m
    }

    /// The six teeth of each hub, turned by `angle` (radians).
    static func teeth(_ m: Shape, angle: CGFloat = 0) -> CGPath {
        let s = m.scale
        let path = CGMutablePath()
        for hub in m.hubs {
            for k in 0..<6 {
                let a = CGFloat(k) * .pi / 3 + .pi / 6 + angle
                let tooth = CGRect(x: -7 * s, y: 18 * s, width: 14 * s, height: 22 * s)
                var t = CGAffineTransform(translationX: hub.x, y: hub.y).rotated(by: a)
                path.addPath(CGPath(roundedRect: tooth, cornerWidth: 4 * s, cornerHeight: 4 * s, transform: &t))
            }
        }
        return path
    }

    /// The menu bar icon: the cassette in the menu bar's own ink (it follows light and dark menu bars), with a
    /// red dot while recording (grey while you're muted in the call), or a dot in the system's accent colour
    /// when an update is ready.
    static func menuBarImage(recording: Bool = false, muted: Bool = false, update: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: 26, height: 18), flipped: false) { rect in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            let m = shape(in: CGRect(x: rect.midX - 12.5, y: rect.midY - 13, width: 25, height: 25))
            cg.setFillColor(NSColor.labelColor.cgColor)
            cg.addPath(m.body)
            cg.fillPath(using: .evenOdd)
            cg.addPath(m.reels)
            cg.fillPath(using: .evenOdd)
            if recording || update {
                let dot = CGRect(x: rect.maxX - 7, y: rect.maxY - 7, width: 7, height: 7)
                // A gap around the dot, cut out of the cassette.
                cg.setBlendMode(.clear)
                cg.fillEllipse(in: dot.insetBy(dx: -1.5, dy: -1.5))
                cg.setBlendMode(.normal)
                cg.setFillColor((recording ? (muted ? NSColor.systemGray : NSColor.systemRed) : NSColor.controlAccentColor).cgColor)
                cg.fillEllipse(in: dot)
            }
            return true
        }
        // Without a dot, a template: macOS tints it exactly like the other menu bar icons.
        image.isTemplate = !recording && !update
        return image
    }
}

/// The cassette: `ink` body and reels, the window see-through (or `window`). With `spinning`, the hubs turn.
struct TapeMarkView: View {
    var size: CGFloat = 24
    var ink: Color = Theme.ink
    var window: Color = .clear
    var spinning = false

    var body: some View {
        if spinning {
            TimelineView(.animation) { context in
                mark(angle: CGFloat(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 6) / 6 * 2 * .pi))
            }
        } else {
            mark(angle: 0)
        }
    }

    private func mark(angle: CGFloat) -> some View {
        Canvas { context, canvasSize in
            let m = TapeMark.shape(in: CGRect(origin: .zero, size: canvasSize))
            let flip = CGAffineTransform(translationX: 0, y: canvasSize.height).scaledBy(x: 1, y: -1)
            context.fill(Path(m.window).applying(flip), with: .color(window))
            context.fill(Path(m.body).applying(flip), with: .color(ink), style: FillStyle(eoFill: true))
            context.fill(Path(m.reels).applying(flip), with: .color(ink), style: FillStyle(eoFill: true))
            if canvasSize.width >= 40 {
                // Turning clockwise as seen (the path is y-up, so the angle runs backwards).
                context.fill(Path(TapeMark.teeth(m, angle: -angle)).applying(flip), with: .color(ink))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Components

/// The cassette and the name.
struct Wordmark: View {
    var body: some View {
        HStack(spacing: 8) {
            TapeMarkView(size: 24)
            Text("Tape").font(Theme.display(17, .bold)).tracking(-0.5)
        }
    }
}

/// Buttons: ink (prominent) or outlined (quiet).
struct PillButtonStyle: ButtonStyle {
    enum Kind { case prominent, quiet }
    var kind: Kind = .prominent

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, kind: kind).pointerCursor()
    }
}

private struct PillBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: PillButtonStyle.Kind
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @State private var hovering = false

    var body: some View {
        let small = controlSize == .small || controlSize == .mini
        configuration.label
            .lineLimit(1).fixedSize()
            .font(Theme.sans(small ? 12.5 : 13, .semibold))
            .padding(.horizontal, small ? 10 : 14).padding(.vertical, small ? 5 : 8)
            .foregroundStyle(kind == .quiet ? Theme.ink : Theme.onInk)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius)
                    .fill(kind == .prominent ? Theme.ink : hovering ? Theme.fill : Theme.raised)
            )
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(kind == .quiet ? Theme.line : .clear))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : kind == .prominent && hovering ? 0.85 : 1) : 0.35)
            .contentShape(RoundedRectangle(cornerRadius: Theme.radius))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var pill: PillButtonStyle { PillButtonStyle() }
    static var pillQuiet: PillButtonStyle { PillButtonStyle(kind: .quiet) }
}

/// Small borderless icon button, darker on hover.
struct IconButton: View {
    let systemImage: String
    let help: String
    var box: CGFloat = 28
    var icon: CGFloat = 13
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage).font(.system(size: icon, weight: .medium))
                .frame(width: box, height: box)
                .foregroundStyle(hovering ? Theme.ink : Theme.ink2)
                .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Theme.fill : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plainPointer)
        .help(help)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// An icon and a label, borderless ("Copy", "Open .md").
struct TextIconButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 12, weight: .medium))
                Text(title).font(Theme.sans(12.5))
            }
            .foregroundStyle(hovering ? Theme.ink : Theme.ink2)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Theme.fill : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainPointer)
        .onHover { hovering = $0 }
    }
}

/// The search box, with its ⌘K hint.
struct SearchField: View {
    let prompt: String
    @Binding var text: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.ink3)
            TextField(prompt, text: $text).textFieldStyle(.plain).font(Theme.sans(13)).focused(focused)
            if text.isEmpty {
                Text("⌘K").font(Theme.mono(11)).foregroundStyle(Theme.ink3)
            } else {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.ink3) }
                    .buttonStyle(.plainPointer)
            }
        }
        .padding(.horizontal, 11).frame(height: 32)
        .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.fill))
    }
}

/// A small label in capitals ("TODAY", "CALLS").
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(Theme.sans(11, .medium)).tracking(0.6).foregroundStyle(Theme.ink3)
    }
}

/// Grouped settings card with hairline-separated rows.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(spacing: 0) { content() }
            .background(RoundedRectangle(cornerRadius: Theme.radiusMedium).fill(Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusMedium).strokeBorder(Theme.line))
    }
}

/// One settings row: title, detail, and a control.
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    var last = false
    @ViewBuilder var control: () -> Control

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(Theme.sans(13.5, .medium)).foregroundStyle(Theme.ink)
                    if let detail {
                        Text(detail).font(Theme.sans(12.5)).foregroundStyle(Theme.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                control()
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            if !last { Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 16) }
        }
    }
}

/// An empty or waiting state.
struct EmptyState: View {
    let title: String
    var detail: String?

    var body: some View {
        VStack(spacing: 6) {
            Text(title).font(Theme.sans(14, .semibold)).foregroundStyle(Theme.ink2)
            if let detail {
                Text(detail).font(Theme.sans(13)).foregroundStyle(Theme.ink3).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(RoundedRectangle(cornerRadius: Theme.radiusLarge).strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
    }
}

/// A spinning ring: something is being worked on (still, under Reduce Motion).
struct Spinner: View {
    var size: CGFloat = 11
    var color: Color = Theme.ink2
    @State private var turning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle().trim(from: 0.15, to: 1)
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(turning ? 360 : 0))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { turning = true }
            }
            .accessibilityHidden(true)
    }
}

/// Seconds as "0:12", "1:04:09".
enum Counter {
    static func text(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.isFinite ? max(0, seconds) : 0)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Pointer cursor

extension View {
    /// The pointing-hand cursor while the pointer is over this view.
    func pointerCursor(_ enabled: Bool = true) -> some View {
        onContinuousHover { phase in
            guard enabled else { return }
            switch phase {
            case .active: NSCursor.pointingHand.set()
            case .ended: NSCursor.arrow.set()
            }
        }
    }
}

struct PlainPointerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1).pointerCursor()
    }
}

extension ButtonStyle where Self == PlainPointerButtonStyle {
    static var plainPointer: PlainPointerButtonStyle { PlainPointerButtonStyle() }
}
