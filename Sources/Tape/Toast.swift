import AppKit
import SwiftUI

/// The dark card above the Dock ("Meeting detected", "Recap ready"), in Onword's style: 416 pt wide, an icon
/// tile, a title over a line of detail, and up to two buttons. It floats over every Space, full-screen calls
/// included, and never takes focus from the call. One card at a time.
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
        var message: String?
        var primary: Action?
        var secondary: Action?
        var timeout: TimeInterval? = 8
        /// Called when the card goes away without a button being used (closed, or timed out).
        var onDismiss: (() -> Void)?
    }

    private var panel: NSPanel?
    private var current: Card?
    private var hideWork: DispatchWorkItem?

    func show(_ card: Card) {
        hide(used: true)
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        let view = FirstClickHostingView(rootView: CardView(card: card) { [weak self] action in
            if let action { action.run() }
            self?.hide(used: action != nil)
        })
        let size = view.fittingSize
        panel.setContentSize(size)
        panel.contentView = view
        // Centred above the Dock.
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: (frame.midX - size.width / 2).rounded(), y: frame.minY + 14))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; panel.animator().alphaValue = 1 }
        self.panel = panel
        current = card
        if let timeout = card.timeout {
            let work = DispatchWorkItem { [weak self] in self?.hide(used: false) }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
        }
    }

    func dismiss(_ id: String) {
        if current?.id == id { hide(used: false) }
    }

    private func hide(used: Bool) {
        hideWork?.cancel()
        hideWork = nil
        if !used { current?.onDismiss?() }
        current = nil
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; panel.animator().alphaValue = 0 },
                                            completionHandler: { panel.orderOut(nil) })
    }
}

/// Buttons work on the first click, without the card's window becoming key.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct CardView: View {
    let card: Toast.Card
    let done: (Toast.Action?) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08))
                .overlay(Image(systemName: card.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(hex: 0xDEDDD7)))
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title).font(Theme.sans(15, .medium)).foregroundStyle(Color(hex: 0xFCFCFB)).lineLimit(1)
                if let message = card.message {
                    Text(message).font(Theme.sans(12)).foregroundStyle(Color(hex: 0x9D9C98)).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let secondary = card.secondary {
                Button { done(secondary) } label: {
                    Text(secondary.title).font(Theme.sans(12, .semibold)).foregroundStyle(Color(hex: 0xE9E8E1))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(hex: 0x30302F)))
                }
                .buttonStyle(.plainPointer)
            }
            if let primary = card.primary {
                Button { done(primary) } label: {
                    HStack(spacing: 8) {
                        if let symbol = primary.symbol {
                            RoundedRectangle(cornerRadius: 5).fill(Color(hex: 0x1A1A1A))
                                .overlay(Image(systemName: symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.lumen))
                                .frame(width: 22, height: 22)
                        }
                        Text(primary.title).font(Theme.sans(12, .semibold))
                    }
                    .foregroundStyle(Color(hex: 0x1A1A1A))
                    .padding(.leading, primary.symbol == nil ? 12 : 6).padding(.trailing, 14)
                    .padding(.vertical, primary.symbol == nil ? 8 : 5)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.lumen))
                }
                .buttonStyle(.plainPointer)
            }
        }
        .padding(14)
        .frame(width: 416)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(hex: 0x1F1F1F)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color(hex: 0x30302F), lineWidth: 1.5))
        .overlay(alignment: .topLeading) {
            if hovering {
                Button { done(nil) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color(hex: 0x1A1A1A).opacity(0.95)))
                        .overlay(Circle().strokeBorder(Color(hex: 0x2C2C2C)))
                }
                .buttonStyle(.plainPointer)
                .offset(x: -8, y: -10)
                .help("Dismiss")
            }
        }
        // Room for the close button and the shadow.
        .padding(.top, 12).padding(.leading, 10).padding(.trailing, 4).padding(.bottom, 16)
        .shadow(color: .black.opacity(0.38), radius: 16, y: 8)
        .onHover { hovering = $0 }
        .environment(\.colorScheme, .dark)
    }
}
