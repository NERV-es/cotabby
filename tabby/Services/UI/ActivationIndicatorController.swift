import AppKit
import Foundation
import SwiftUI

/// File overview:
/// Owns the tiny non-activating panel that marks supported inputs with a subtle caret anchor.
/// Unlike the ghost-text overlay, this controller is focus-driven and anchors to the resolved caret
/// instead of the full input frame.
///
/// Keeping this as a separate controller preserves the architectural split between:
/// supported-field affordances and suggestion-specific UI.
@MainActor
final class ActivationIndicatorController {
    private let verticalGap: CGFloat = 2
    private let screenInset: CGFloat = 2

    private lazy var contentView: NSHostingView<ActivationIndicatorView> = {
        NSHostingView(rootView: ActivationIndicatorView())
    }()

    private lazy var panel: ActivationIndicatorPanel = {
        let panel = ActivationIndicatorPanel(
            contentRect: CGRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = contentView
        return panel
    }()

    private var lastCaretRect: CGRect?

    /// Sizes and positions the activation icon above the resolved caret.
    ///
    /// This is deliberately caret-based rather than field-based. The old outside-left placement
    /// proved too disconnected from the user's insertion point, especially in large editors.
    /// Anchoring to the caret makes the affordance feel attached to the text flow itself.
    func show(at caretRect: CGRect) {
        guard !caretRect.isEmpty else {
            hide(reason: "Activation indicator hidden because the caret rect was empty.")
            return
        }

        contentView.layoutSubtreeIfNeeded()
        let contentSize = contentView.fittingSize
        let frame = CGRect(
            origin: origin(for: caretRect, contentSize: contentSize),
            size: contentSize
        ).integral

        if lastCaretRect == caretRect, panel.frame == frame, panel.isVisible {
            return
        }

        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        lastCaretRect = caretRect
    }

    /// Hides the indicator when Tabby is not actively supporting the current field.
    func hide(reason _: String) {
        panel.orderOut(nil)
        lastCaretRect = nil
    }

    /// Centers the indicator horizontally on the caret and prefers placing it just below the
    /// current line box. If the caret is too close to the bottom edge of the visible screen,
    /// we fall back above the line instead.
    private func origin(for caretRect: CGRect, contentSize: CGSize) -> CGPoint {
        let centeredX = caretRect.midX - (contentSize.width / 2)
        let preferredBelowY = caretRect.minY - contentSize.height - verticalGap

        guard let screen = screen(for: caretRect) else {
            return CGPoint(x: centeredX, y: preferredBelowY)
        }

        let visibleFrame = screen.visibleFrame
        let fallbackAboveY = caretRect.maxY + verticalGap
        let preferredY: CGFloat
        if preferredBelowY >= visibleFrame.minY + screenInset {
            preferredY = preferredBelowY
        } else {
            preferredY = fallbackAboveY
        }

        let clampedX = min(
            max(centeredX, visibleFrame.minX + screenInset),
            visibleFrame.maxX - contentSize.width - screenInset
        )
        let clampedY = min(
            max(preferredY, visibleFrame.minY + screenInset),
            visibleFrame.maxY - contentSize.height - screenInset
        )

        return CGPoint(x: clampedX, y: clampedY)
    }

    /// Chooses the screen that currently contains the caret's center point.
    private func screen(for caretRect: CGRect) -> NSScreen? {
        let midpoint = CGPoint(x: caretRect.midX, y: caretRect.midY)

        if let containingScreen = NSScreen.screens.first(where: {
            $0.visibleFrame.contains(midpoint)
        }) {
            return containingScreen
        }

        return NSScreen.screens.first(where: { $0.frame.intersects(caretRect) })
    }
}

private final class ActivationIndicatorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct ActivationIndicatorView: View {
    @Environment(\.colorScheme) private var colorScheme

    private var bgColor: Color {
        colorScheme == .dark ? Color(white: 0.18) : Color(white: 0.95)
    }

    var body: some View {
        CaretPointerTriangle(cornerRadius: 1.5)
            .fill(bgColor)
            .frame(width: 8, height: 5)
            .shadow(color: .black.opacity(0.16), radius: 1, y: 1)
            .fixedSize()
    }
}

/// A small upward triangle reads as a pointer to the insertion point when it sits below the line.
/// Rounded corners make it feel softer and visually closer to the ghost keycap styling.
private struct CaretPointerTriangle: Shape {
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = min(cornerRadius, rect.width * 0.2, rect.height * 0.35)
        let apex = CGPoint(x: rect.midX, y: rect.minY)
        let right = CGPoint(x: rect.maxX, y: rect.maxY)
        let left = CGPoint(x: rect.minX, y: rect.maxY)

        func insetPoint(from corner: CGPoint, toward other: CGPoint, by distance: CGFloat) -> CGPoint {
            let dx = other.x - corner.x
            let dy = other.y - corner.y
            let length = max(sqrt(dx * dx + dy * dy), 0.0001)
            return CGPoint(
                x: corner.x + (dx / length) * distance,
                y: corner.y + (dy / length) * distance
            )
        }

        let apexRight = insetPoint(from: apex, toward: right, by: radius)
        let apexLeft = insetPoint(from: apex, toward: left, by: radius)
        let rightTop = insetPoint(from: right, toward: apex, by: radius)
        let rightBottom = insetPoint(from: right, toward: left, by: radius)
        let leftBottom = insetPoint(from: left, toward: right, by: radius)
        let leftTop = insetPoint(from: left, toward: apex, by: radius)

        var path = Path()
        path.move(to: apexRight)
        path.addQuadCurve(to: apexLeft, control: apex)
        path.addLine(to: leftTop)
        path.addQuadCurve(to: leftBottom, control: left)
        path.addLine(to: rightBottom)
        path.addQuadCurve(to: rightTop, control: right)
        path.closeSubpath()
        return path
    }
}
