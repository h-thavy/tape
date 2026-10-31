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
        /// Shown instead of the symbol: the call platform's icon.
        var image: NSImage?
        let title: String
        /// In monospaced type after the title ("42:10").
        var detail: String?
        var message: String?
        var primary: Action?
        var secondary: Action?
        var timeout: TimeInterval? = 8
        /// Something to answer: light runs around the island's edge while it waits.
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

    /// The island is yours, not the meeting's: kept out of screen sharing and screen recording, so it isn't
    /// seen when you share your whole screen. (TAPE_TEST_SHARED=1 leaves it in, to compare.)
    static let captureSharing: NSWindow.SharingType =
        ProcessInfo.processInfo.environment["TAPE_TEST_SHARED"] != nil ? .readOnly : .none
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
        panel.sharingType = Toast.captureSharing
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
        var cards: [(String, Card)] = [
            ("island-meeting", Card(id: "call", symbol: "video", title: "Meeting detected", message: "Google Meet in Opera GX",
                                    primary: .init(title: "Record", symbol: "record.circle") {}, secondary: .init(title: "Not now") {},
                                    timeout: nil, attention: true)),
            ("island-saved", Card(id: "saved", symbol: "checkmark.circle", title: "Recording saved", detail: "42:10",
                                  message: "Weekly sync with Ploy HR", primary: .init(title: "Transcribe + summarize", symbol: "sparkles") {},
                                  secondary: .init(title: "Open") {})),
            ("island-recap", Card(id: "recap", symbol: "doc.text", title: "Recap ready", message: "AI-Powered CV Automation · 6 topics",
                                  primary: .init(title: "Open") {})),
        ]
        var teams = cards[0].1
        teams.image = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.teams2")
            .map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSWorkspace.shared.icon(forFile: "/System/Applications/FaceTime.app")
        teams = Card(id: "call", symbol: "video", image: teams.image, title: "Meeting detected", message: "Microsoft Teams",
                     primary: teams.primary, secondary: teams.secondary, timeout: nil, attention: true)
        cards.append(("island-meeting-teams", teams))
        let meeting = cards[0].1
        let glows: [(String, Card, Double?)] = cards.map { ($0.0, $0.1, nil) }
            + [0.15, 0.35, 0.55, 0.75, 0.95, 1.1, 1.25].enumerated().map { ("island-glow-\($0.offset + 1)", meeting, $0.element) }
        for (name, card, glowAt) in glows {
            var island = IslandView(card: card, notch: CGSize(width: 185, height: 32), model: Model(open: true)) { _ in }
            island.glowAt = glowAt
            let view = NSHostingView(rootView: island.background(Color(hex: 0x2A2A2E)))
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
    /// Without the top edge (for drawing an outline that stops at the screen's edge).
    var open = false

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
        if !open { p.closeSubpath() }
        return p
    }
}

/// White light running down the island's edge: two streaks start at the top corners, where the island meets
/// the screen's edge, run down the sides and along the bottom, and meet in the middle with a soft flash.
/// Every few seconds while the island waits for an answer, the first run brightest. A faint still rim under
/// Reduce Motion.
private struct AttentionGlow: View {
    let start: Date
    var frozen = false

    /// One run and its flash, then a pause.
    private static let cycle = 2.8, run = 1.1, flash = 0.5

    var body: some View {
        if Toast.reduceMotion {
            IslandShape(open: true).stroke(Color.white.opacity(0.35), lineWidth: 1).allowsHitTesting(false).accessibilityHidden(true)
        } else {
            TimelineView(.animation(paused: frozen)) { context in
                let t = max(0, context.date.timeIntervalSince(start))
                let local = t.truncatingRemainder(dividingBy: Self.cycle)
                let strength = t < Self.cycle ? 1 : 0.6
                // Eased in and out: gathering speed from the corners, slowing as the two meet.
                let x = min(local / Self.run, 1)
                let head = x * x * (3 - 2 * x)
                let flash = local > Self.run ? max(0, 1 - (local - Self.run) / Self.flash) : 0
                ZStack {
                    if local < Self.run + 0.25 {
                        streak(.left, head: head, strength: strength * (local < Self.run ? 1 : 1 - (local - Self.run) / 0.25))
                        streak(.right, head: head, strength: strength * (local < Self.run ? 1 : 1 - (local - Self.run) / 0.25))
                    }
                    if flash > 0 { meeting(flash: flash * strength) }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }

    /// A streak with a smoothly fading tail: the tail in 12 short pieces, each brighter towards the head.
    private func streak(_ side: IslandHalf.Side, head: Double, strength: Double) -> some View {
        let tail = 0.32, pieces = 12
        return ZStack {
            ForEach(0..<pieces, id: \.self) { k in
                let from = head - tail * Double(pieces - k) / Double(pieces)
                let to = head - tail * Double(pieces - k - 1) / Double(pieces)
                IslandHalf(side: side).trim(from: max(0, from), to: max(0, to))
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 1.6, lineCap: .butt))
                    .opacity(pow(Double(k + 1) / Double(pieces), 1.6) * strength)
            }
            IslandHalf(side: side).trim(from: max(0, head - 0.12), to: head)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .blur(radius: 6).opacity(0.5 * strength)
        }
    }

    /// Where the two streaks meet: a short glow on the bottom edge.
    private func meeting(flash: Double) -> some View {
        GeometryReader { geometry in
            Capsule().fill(Color.white)
                .frame(width: 40 + 90 * (1 - flash), height: 3)
                .blur(radius: 4 + 4 * (1 - flash))
                .position(x: geometry.size.width / 2, y: geometry.size.height - 0.5)
                .opacity(0.9 * flash)
        }
    }
}

/// One half of the island's outline without its top edge: from a top corner down the side and along the
/// bottom to the middle.
private struct IslandHalf: Shape {
    enum Side { case left, right }
    let side: Side
    var flare: CGFloat = 8
    var radius: CGFloat = 24

    func path(in rect: CGRect) -> Path {
        let f = min(flare, rect.width / 4), r = min(radius, rect.height / 2, (rect.width - 2 * f) / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + f, y: rect.minY + f), control: CGPoint(x: rect.minX + f, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + f, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.minX + f + r, y: rect.maxY), control: CGPoint(x: rect.minX + f, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        guard side == .right else { return p }
        return p.applying(CGAffineTransform(translationX: rect.maxX + rect.minX, y: 0).scaledBy(x: -1, y: 1))
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
    /// Debug snapshots: the glow as it is this many seconds after opening.
    var glowAt: Double?
    @State private var glowStart: Date?

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
                .overlay {
                    if card.attention, model.open, glowStart != nil || glowAt != nil {
                        AttentionGlow(start: glowStart ?? Date().addingTimeInterval(-(glowAt ?? 0)), frozen: glowAt != nil)
                    }
                }
                .onChange(of: model.open) {
                    // Once the island has grown to full size.
                    if model.open, card.attention {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { glowStart = Date() }
                    } else {
                        glowStart = nil
                    }
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
            Group {
                if let image = card.image {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        .frame(width: 34, height: 34)
                } else {
                    RoundedRectangle(cornerRadius: 9).fill(Theme.Island.tile)
                        .overlay(Image(systemName: card.symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.Island.text))
                }
            }
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
