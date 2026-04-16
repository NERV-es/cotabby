import AppKit
import Foundation
import SwiftUI

/// File overview:
/// Owns the non-activating floating panel that renders ghost text near the caret. AppKit window
/// behavior stays isolated here so the coordinator only has to reason about overlay state.
///
/// This separation matters because overlay bugs are often windowing bugs, not state-machine bugs.
/// By keeping the panel lifecycle here, `SuggestionCoordinator` can stay focused on suggestion logic.
@MainActor
final class OverlayController: SuggestionOverlayControlling {
    var onStateChange: ((OverlayState) -> Void)?

    private(set) var state: OverlayState = .hidden(reason: "Overlay idle.") {
        didSet {
            onStateChange?(state)
        }
    }

    private lazy var panel: OverlayPanel = {
        let panel = OverlayPanel(
            contentRect: CGRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        // A non-activating panel lets Tabby draw UI near the caret without stealing focus
        // from the app the user is actively typing into.
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        return panel
    }()

    /// Sizes and positions the overlay next to the reported caret bounds for the current field.
    func showSuggestion(_ text: String, at caretRect: CGRect) {
        guard !text.isEmpty else {
            hide(reason: "Overlay not shown because the suggestion was empty.")
            return
        }

        let contentView = NSHostingView(rootView: GhostSuggestionView(text: text))
        contentView.layoutSubtreeIfNeeded()
        let contentSize = contentView.fittingSize

        // Vertically center the ghost text within the caret rect. When the caret rect is a
        // tight line-height box this looks identical to top-alignment, but when it's oversized
        // (e.g. AXFrame fallback returning the full text area) the text lands at the visual
        // midpoint instead of floating at the top edge.
        let origin = CGPoint(
            x: caretRect.maxX + 6,
            y: caretRect.midY - contentSize.height / 2
        )
        let frame = CGRect(origin: origin, size: contentSize)

        panel.contentView = contentView
        panel.setFrame(frame.integral, display: true)
        panel.orderFrontRegardless()
        state = .visible(text: text, caretRect: caretRect)
    }

    /// Hides the floating panel and records why the overlay is no longer visible.
    func hide(reason: String) {
        panel.orderOut(nil)
        state = .hidden(reason: reason)
    }
}

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Small SwiftUI view hosted inside the floating AppKit panel.
/// Keeping the rendered content separate from the window controller makes styling easier to evolve
/// without touching the AppKit positioning code.
private struct GhostSuggestionView: View {
    @Environment(\.colorScheme) var colorScheme
    let text: String

    var ghostColor: Color {
        colorScheme == .dark
            ? Color(red: 0.65, green: 0.65, blue: 0.65)
            : Color(red: 0.45, green: 0.45, blue: 0.45)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(ghostColor)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: true)

            GhostTabKeycap()
        }
        .fixedSize(horizontal: true, vertical: true)
    }
}

/// Visual hint that teaches the user which key accepts the suggestion.
/// We intentionally render only the tab glyph now; the explicit "Tab" label took too much visual
/// weight for an inline hint that should stay secondary to the suggestion itself.
private struct GhostTabKeycap: View {
    @Environment(\.colorScheme) var colorScheme

    var textColor: Color {
        colorScheme == .dark ? Color(white: 0.65) : Color(white: 0.45)
    }

    var bgColor: Color {
        colorScheme == .dark ? Color(white: 0.18) : Color(white: 0.95)
    }

    var borderColor: Color {
        colorScheme == .dark ? Color(white: 0.3) : Color(white: 0.8)
    }

    var body: some View {
        Text("⇥")
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(textColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(bgColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.4 : 0.08),
                radius: 1,
                x: 0,
                y: 1
            )
            .fixedSize(horizontal: true, vertical: true)
    }
}
