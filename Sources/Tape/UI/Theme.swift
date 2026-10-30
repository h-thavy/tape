import AppKit
import SwiftUI

/// Design tokens shared with Onword: warm "sand" neutrals, near-black ink, EB Garamond headlines and Figtree
/// text. Every colour has a light and a dark variant.
enum Theme {
    // MARK: Colours

    /// Window frame behind the sidebar.
    static let frame = dynamic(light: 0xF5F4F0, dark: 0x202020)
    /// Main content panel.
    static let panel = dynamic(light: 0xFFFFFF, dark: 0x1A1A1A)
    /// Cards and rows on the panel.
    static let card = dynamic(light: 0xFCFCFB, dark: 0x2A2A29)
    static let border = dynamic(light: 0xEEEBE3, dark: 0x30302F)
    static let ink = dynamic(light: 0x1A1A1A, dark: 0xE9E8E1)
    static let inkSecondary = dynamic(light: 0x464544, dark: 0xC8C8C2)
    static let inkTertiary = dynamic(light: 0x71716E, dark: 0x9D9C98)
    static let primary = dynamic(light: 0x1A1A1A, dark: 0xFCFCFB)
    static let onPrimary = dynamic(light: 0xFCFCFB, dark: 0x1A1A1A)
    /// The page panel: warm off-white, not pure white.
    static let page = dynamic(light: 0xFCFCFB, dark: 0x1A1A1A)
    /// Status cards.
    static let mutedCard = dynamic(light: 0xF1EBE1, dark: 0x30302F)
    static let iconFaint = dynamic(light: 0xB3B2AD, dark: 0x9D9C98)
    static let outline = dynamic(light: 0xC5C0B3, dark: 0x5B5B59)
    /// Secondary buttons and the selected sidebar item.
    static let buttonFill = dynamic(light: 0xEEEBE3, dark: 0x30302F)
    /// Lavender accent for highlights.
    static let accent = dynamic(light: 0xF4E1FF, dark: 0x3C2947)
    static let onAccent = dynamic(light: 0x502B66, dark: 0xF0D7FF)
    static let recording = Color(red: 0.86, green: 0.2, blue: 0.18)
    static let success = Color(hex: 0x10B981)
    /// The pale "lumen" fill of the call-to-action on dark cards.
    static let lumen = Color(hex: 0xFFFFEB)

    // MARK: Type

    static func serif(_ size: CGFloat, italic: Bool = false) -> Font {
        .custom(italic ? "EBGaramond-Italic" : "EBGaramond-Regular", size: size)
    }

    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Figtree", size: size).weight(weight)
    }

    // MARK: Shape

    static let radius: CGFloat = 8
    static let radiusMedium: CGFloat = 12
    static let radiusLarge: CGFloat = 16

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: - Mark

/// Tape's mark: a cassette. Same geometry as scripts/make-icon.swift, which renders the app icon.
enum TapeMark {
    /// The cassette in `box` (a square, y-up): the body with its window and the notch cut out (fill even-odd),
    /// the window, and the two reels (even-odd).
    static func paths(in box: CGRect) -> (body: CGPath, window: CGPath, reels: CGPath) {
        let s = box.width / 1024
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: box.minX + x * s, y: box.minY + y * s) }
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(origin: p(x, y), size: CGSize(width: w * s, height: h * s))
        }
        let window = CGPath(roundedRect: r(240, 478, 544, 180), cornerWidth: 40 * s, cornerHeight: 40 * s, transform: nil)
        let body = CGMutablePath()
        body.addRoundedRect(in: r(112, 300, 800, 460), cornerWidth: 64 * s, cornerHeight: 64 * s)
        body.addPath(window)
        // The notch along the bottom edge, where the tape meets the head.
        body.move(to: p(322, 300)); body.addLine(to: p(366, 364)); body.addLine(to: p(658, 364)); body.addLine(to: p(702, 300))
        body.closeSubpath()
        let reels = CGMutablePath()
        for cx: CGFloat in [372, 652] {
            reels.addEllipse(in: r(cx - 64, 568 - 64, 128, 128))
            reels.addEllipse(in: r(cx - 26, 568 - 26, 52, 52))
        }
        return (body, window, reels)
    }

    /// The menu bar icon: the cassette in the menu bar's own ink (it follows light and dark menu bars), with a
    /// red dot while recording (grey while you're muted in the call).
    static func menuBarImage(recording: Bool = false, muted: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: 27, height: 18), flipped: false) { rect in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            let mark = paths(in: CGRect(x: rect.midX - 13, y: rect.midY - 13.5, width: 26, height: 26))
            cg.addPath(mark.body)
            cg.setFillColor(NSColor.labelColor.cgColor)
            cg.fillPath(using: .evenOdd)
            cg.addPath(mark.reels)
            cg.fillPath(using: .evenOdd)
            if recording {
                let dot = CGRect(x: rect.maxX - 7.5, y: rect.maxY - 7, width: 7, height: 7)
                cg.setFillColor(NSColor.windowBackgroundColor.cgColor)
                cg.fillEllipse(in: dot.insetBy(dx: -1.2, dy: -1.2))
                cg.setFillColor((muted ? NSColor.systemGray : NSColor.systemRed).cgColor)
                cg.fillEllipse(in: dot)
            }
            return true
        }
        // Without a dot, a template: macOS tints it exactly like the other menu bar icons.
        image.isTemplate = !recording
        return image
    }
}

struct TapeMarkView: View {
    var size: CGFloat = 24

    var body: some View {
        Canvas { context, canvasSize in
            let mark = TapeMark.paths(in: CGRect(origin: .zero, size: canvasSize))
            let flip = CGAffineTransform(translationX: 0, y: canvasSize.height).scaledBy(x: 1, y: -1)
            context.fill(Path(mark.window).applying(flip), with: .color(Theme.accent))
            context.fill(Path(mark.body).applying(flip), with: .color(Theme.ink), style: FillStyle(eoFill: true))
            context.fill(Path(mark.reels).applying(flip), with: .color(Theme.ink), style: FillStyle(eoFill: true))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Components

/// Page title row: 24 pt semibold title, actions on the right.
struct PageHeader<Actions: View>: View {
    let title: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title).font(Theme.sans(24, .semibold)).foregroundStyle(Theme.ink)
            Spacer()
            actions()
        }
    }
}

/// Hero card: a serif headline with one italic word, a sentence, and an action.
struct HeroCard<Action: View>: View {
    let before: String
    let italic: String
    let after: String
    let message: String
    @ViewBuilder var action: () -> Action

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(before)\(Text(italic).font(Theme.serif(28, italic: true)))\(after)")
                .font(Theme.serif(28)).tracking(-1.12)
                .foregroundStyle(Theme.ink)
            Text(message).font(Theme.sans(15)).foregroundStyle(Theme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
            action().padding(.top, 16)
        }
        .padding(32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radiusLarge).fill(Theme.accent.opacity(0.55)))
    }
}

/// Primary (dark) or secondary (sand) button: radius 8, 15 pt, 36 tall — or 32 at `.small`.
struct PillButtonStyle: ButtonStyle {
    var prominent = true
    var tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, prominent: prominent, tint: tint).pointerCursor()
    }
}

private struct PillBody: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    let tint: Color?
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    var body: some View {
        let small = controlSize == .small || controlSize == .mini
        configuration.label
            .lineLimit(1).fixedSize()
            .font(Theme.sans(small ? 13.5 : 15, prominent ? .medium : .semibold))
            .padding(.horizontal, small ? 12 : 16).padding(.vertical, small ? 6 : 8)
            .foregroundStyle(prominent ? (tint == nil ? Theme.onPrimary : .white) : Theme.ink)
            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(prominent ? (tint ?? Theme.primary) : Theme.buttonFill))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: Theme.radius))
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var pill: PillButtonStyle { PillButtonStyle() }
    static var pillQuiet: PillButtonStyle { PillButtonStyle(prominent: false) }
    static var pillRecord: PillButtonStyle { PillButtonStyle(tint: Theme.recording) }
}

/// Small borderless icon button that darkens on hover.
struct IconButton: View {
    let systemImage: String
    let help: String
    var box: CGFloat = 28
    var icon: CGFloat = 15
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage).font(.system(size: icon))
                .frame(width: box, height: box)
                .foregroundStyle(hovering ? Theme.ink : Theme.inkTertiary)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Theme.frame : .clear))
        }
        .buttonStyle(.plainPointer)
        .help(help)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// Rounded search field.
struct SearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(Theme.inkTertiary)
            TextField(prompt, text: $text).textFieldStyle(.plain).font(Theme.sans(15))
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.inkTertiary) }
                    .buttonStyle(.plainPointer)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border))
    }
}

/// Uppercase group label ("TODAY").
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(Theme.sans(12, .semibold)).tracking(0.9).foregroundStyle(Theme.inkTertiary)
    }
}

/// A table row that reveals its trailing actions on hover.
struct HoverRow<Content: View, Actions: View>: View {
    @ViewBuilder var content: () -> Content
    @ViewBuilder var actions: () -> Actions
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.init(top: 14, leading: 16, bottom: 14, trailing: 4))
            actions()
                .opacity(hovering ? 1 : 0)
                .padding(.trailing, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? Theme.frame : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// One rounded list table: hairline-separated rows inside a 16-radius, 1-pt border.
struct TableCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) { content() }
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusLarge))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusLarge).strokeBorder(Theme.border))
    }
}

/// Grouped settings card with hairline-separated rows.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(spacing: 0) { content() }
            .background(RoundedRectangle(cornerRadius: Theme.radiusMedium).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusMedium).strokeBorder(Theme.border))
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
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.sans(14, .medium)).foregroundStyle(Theme.ink)
                    if let detail {
                        Text(detail).font(Theme.sans(12.5)).foregroundStyle(Theme.inkTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                control()
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            if !last { Divider().overlay(Theme.border).padding(.leading, 16) }
        }
    }
}

/// A selectable underline tab: 15 pt semibold, 2-pt ink underline when selected.
struct UnderlineTab: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(Theme.sans(15, .semibold)).foregroundStyle(selected ? Theme.ink : Theme.inkTertiary)
                .padding(.vertical, 10).padding(.horizontal, 12)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(selected ? Theme.ink : .clear).frame(height: 2).padding(.horizontal, 12)
                }
        }
        .buttonStyle(.plainPointer)
    }
}

/// A list's empty state: centred message on a sand tile.
struct EmptyState: View {
    let title: String
    var detail: String?

    var body: some View {
        VStack(spacing: 6) {
            Text(title).font(Theme.sans(16, .medium))
            if let detail {
                Text(detail).font(Theme.sans(15)).foregroundStyle(Theme.inkTertiary).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(RoundedRectangle(cornerRadius: Theme.radiusLarge).fill(Theme.frame))
    }
}

/// Standard page body: scrollable, centred, 40 pt of padding.
struct PageScroll<Content: View>: View {
    var maxWidth: CGFloat = 820
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) { content() }
                .frame(maxWidth: maxWidth, alignment: .leading)
                .padding(40)
                .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
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
        configuration.label.pointerCursor()
    }
}

extension ButtonStyle where Self == PlainPointerButtonStyle {
    static var plainPointer: PlainPointerButtonStyle { PlainPointerButtonStyle() }
}
