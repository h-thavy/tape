import AppKit
import SwiftUI

/// The island at the top of the screen ("Meeting detected", "Recording saved", "Recap ready"): it grows out of
/// the camera notch (black, so it reads as the notch getting bigger), shows an icon, a title over a line of
/// detail and up to two buttons, and shrinks back into the notch when it's done. On a screen without a notch it
/// drops from the top edge instead. It floats over every Space, full-screen calls included, and never takes
/// focus from the call. One at a time; VoiceOver reads it out when it appears.
@MainActor
final class Toast {
    static let shared = Toast()

    struct Action {
        let title: String
        var symbol: String?
        let run: () -> Void
    }

    struct Card {
        let id: String
        var symbol = "waveform"
        let title: String
        /// In monospaced type after the title ("42:10").
        var detail: String?
        var message: String?
        var primary: Action?
        var secondary: Action?
        var timeout: TimeInterval? = 8
        /// Something to answer: the island glows as it opens.
        var attention = false
        /// Called when the card goes away without a button being used (closed, or timed out).
        var onDismiss: (() -> Void)?
    }

    /// Open (full size) or closed (the size of the notch); the island animates between the two.
    final class Model: ObservableObject {
        @Published var open: Bool
        init(open: Bool = false) { self.open = open }
    }

    static let width: CGFloat = 500

    private var panel: NSPanel?
    private var model: Model?
    private var current: Card?
    /// A card is showing (the notch's quick actions stay closed meanwhile).
    var isShowing: Bool { current != nil }
    private var hideWork: DispatchWorkItem?

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static func spring(_ response: Double, _ damping: Double) -> Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .spring(response: response, dampingFraction: damping)
    }

    func show(_ card: Card) {
        removeNow()
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let notch = Self.notch(on: screen)
        let model = Model()
        let island = IslandView(card: card, notch: notch, model: model) { [weak self] action in
            if let action { action.run() }
            self?.hide(used: action != nil)
        }
        let view = FirstClickHostingView(rootView: island)
        // Full size: the open island's own height, plus room for its shadow.
        let size = NSSize(width: Self.width + 40, height: Self.openSize(card, notch: notch).height)

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        // Above the menu bar, which the island grows over (and above the notch's own island).
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = view
        // Its top on the screen's top edge, centred on the notch.
        panel.setFrameOrigin(NSPoint(x: (screen.frame.midX - size.width / 2).rounded(), y: screen.frame.maxY - size.height))
        panel.orderFrontRegardless()
        self.panel = panel
        self.model = model
        current = card
        DispatchQueue.main.async {
            withAnimation(Self.spring(0.42, 0.78)) { model.open = true }
        }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: [card.title, card.detail, card.message].compactMap { $0 }.joined(separator: ". "),
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
        if let timeout = card.timeout {
            let work = DispatchWorkItem { [weak self] in self?.hide(used: false) }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
        }
    }

    func dismiss(_ id: String) {
        if current?.id == id { hide(used: false) }
    }

    /// Shrinks back into the notch, then goes.
    private func hide(used: Bool) {
        hideWork?.cancel()
        hideWork = nil
        if !used { current?.onDismiss?() }
        current = nil
        guard let panel, let model else { return }
        self.panel = nil
        self.model = nil
        withAnimation(Self.spring(0.32, 0.9)) { model.open = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { panel.orderOut(nil) }
    }

    /// Straight away (a new card replaces the old one).
    private func removeNow() {
        hideWork?.cancel()
        hideWork = nil
        panel?.orderOut(nil)
        panel = nil
        model = nil
        current = nil
    }

    private static func openSize(_ card: Card, notch: CGSize?) -> NSSize {
        NSHostingView(rootView: IslandView(card: card, notch: notch, model: Model(open: true)) { _ in }).fittingSize
    }

    /// Debug: each kind of card drawn into a PNG, open, under a notch like a 14" MacBook Pro's.
    static func snapshots(to folder: URL) {
        let cards: [(String, Card)] = [
            ("island-meeting", Card(id: "call", symbol: "video", title: "Meeting detected", message: "Google Meet in Opera GX",
                                    primary: .init(title: "Record", symbol: "record.circle") {}, secondary: .init(title: "Not now") {})),
            ("island-saved", Card(id: "saved", symbol: "checkmark.circle", title: "Recording saved", detail: "42:10",
                                  message: "Weekly sync with Ploy HR", primary: .init(title: "Make recap", symbol: "sparkles") {},
                                  secondary: .init(title: "Open") {})),
            ("island-recap", Card(id: "recap", symbol: "doc.text", title: "Recap ready", message: "AI-Powered CV Automation · 6 topics",
                                  primary: .init(title: "Open") {})),
        ]
        for (name, card) in cards {
            let view = NSHostingView(rootView: IslandView(card: card, notch: CGSize(width: 185, height: 32), model: Model(open: true)) { _ in }
                .background(Color(hex: 0xC9C9C9)))
            view.frame = NSRect(origin: .zero, size: openSize(card, notch: CGSize(width: 185, height: 32)))
            Snapshot.write(view, to: folder.appendingPathComponent("\(name).png"))
        }
    }

    /// The camera notch's size on `screen`, or nil when it has none.
    static func notch(on screen: NSScreen) -> CGSize? {
        guard screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else {
            return nil
        }
        return CGSize(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
    }
}

/// Buttons work on the first click, without the island's window becoming key first.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The island's outline: flat along the top edge, flaring out into it at the two top corners (as the notch
/// meets the screen's edge), and rounded at the bottom.
struct IslandShape: Shape {
    var flare: CGFloat = 8
    var radius: CGFloat = 24

    func path(in rect: CGRect) -> Path {
        let f = min(flare, rect.width / 4), r = min(radius, rect.height / 2, (rect.width - 2 * f) / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + f, y: rect.minY + f), control: CGPoint(x: rect.minX + f, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + f, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.minX + f + r, y: rect.maxY), control: CGPoint(x: rect.minX + f, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - f - r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - f, y: rect.maxY - r), control: CGPoint(x: rect.maxX - f, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - f, y: rect.minY + f))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - f, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

/// The island's buttons: white (the main one) or translucent.
struct IslandButton: View {
    let title: String
    var symbol: String?
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .bold)) }
                Text(title).font(Theme.sans(12.5, .semibold))
            }
            .fixedSize()
            .foregroundStyle(prominent ? Color.black : Theme.Island.text)
            .padding(.horizontal, 14).frame(height: 32)
            .background(Capsule().fill(prominent ? Color.white : Theme.Island.quiet))
            .contentShape(Capsule())
        }
        .buttonStyle(.plainPointer)
    }
}

private struct IslandView: View {
    let card: Toast.Card
    /// The notch's size; nil on a screen without one.
    let notch: CGSize?
    @ObservedObject var model: Toast.Model
    let done: (Toast.Action?) -> Void
    @State private var glow = false

    /// Below the notch (or the menu bar, where there's none).
    private var top: CGFloat { notch?.height ?? NSStatusBar.system.thickness }

    var body: some View {
        let closed = CGSize(width: (notch?.width ?? 180) + 16, height: notch?.height ?? 0)
        VStack(spacing: 0) {
            content
                .padding(.top, top + 10)
                .padding(.leading, 22).padding(.trailing, 16).padding(.bottom, 16)
                .frame(width: Toast.width)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(model.open ? 1 : 0)
                .scaleEffect(model.open || Toast.reduceMotion ? 1 : 0.9, anchor: .top)
                .frame(width: model.open ? Toast.width : closed.width,
                       height: model.open ? nil : closed.height, alignment: .top)
                .background(IslandShape().fill(Color.black))
                .clipShape(IslandShape())
                .shadow(color: .black.opacity(model.open ? 0.35 : 0), radius: 18, y: 8)
                // Two soft rings going out from the island.
                .overlay {
                    if card.attention && !Toast.reduceMotion {
                        IslandShape().stroke(Color.white.opacity(glow ? 0 : 0.55), lineWidth: glow ? 6 : 2)
                            .scaleEffect(glow ? 1.06 : 1, anchor: .top)
                            .allowsHitTesting(false)
                    }
                }
                .onChange(of: model.open) {
                    guard model.open, card.attention, !Toast.reduceMotion else { return }
                    withAnimation(.easeOut(duration: 1.1).delay(0.35).repeatCount(2, autoreverses: false)) { glow = true }
                }
            Spacer(minLength: 0)
        }
        .frame(width: Toast.width + 40)
        .padding(.bottom, 24)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(card.title)
    }

    private var content: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 9).fill(Theme.Island.tile)
                .overlay(Image(systemName: card.symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.Island.text))
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                titleLine
                if let message = card.message {
                    Text(message).font(Theme.sans(12)).foregroundStyle(Theme.Island.text2).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            if let secondary = card.secondary { IslandButton(title: secondary.title, symbol: secondary.symbol) { done(secondary) } }
            if let primary = card.primary { IslandButton(title: primary.title, symbol: primary.symbol, prominent: true) { done(primary) } }
            close
        }
    }

    private var titleLine: some View {
        HStack(spacing: 8) {
            Text(card.title).font(Theme.sans(14.5, .semibold)).foregroundStyle(Theme.Island.text).lineLimit(1)
                .fixedSize()
            if let detail = card.detail { Text(detail).font(Theme.mono(12)).foregroundStyle(Theme.Island.text2).lineLimit(1).fixedSize() }
        }
    }

    private var close: some View {
        Button { done(nil) } label: {
            Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.Island.text2)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plainPointer)
        .help("Dismiss")
        .accessibilityLabel("Dismiss")
    }
}
