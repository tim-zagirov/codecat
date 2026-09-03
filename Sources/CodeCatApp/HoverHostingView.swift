import AppKit
import SwiftUI

/// An `NSHostingView` that reports when the cursor enters and leaves.
///
/// Hover is caught with `NSTrackingArea` rather than SwiftUI's hover for two
/// reasons: the island's window must not activate and steal focus, and the event
/// is needed even when the app is not active (`.activeAlways`).
class HoverHostingView<Content: View>: NSHostingView<Content> {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        // `.inVisibleRect` avoids recomputing the rectangle every time the window
        // resizes — and it resizes whenever the skin changes.
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}

/// The island's host view: on top of hover it reports a click — but only on the
/// island strip itself.
///
/// One window holds both the island and the menu, so "a click on the island" is no
/// longer the same as "a click on the window". Everything below the strip belongs
/// to the menu's content — toggles, the skin picker, session rows — and events
/// must reach it untouched, or everything inside the menu stops working at once.
///
/// `mouseDown` on the strip is swallowed deliberately and the action hangs off
/// `mouseUp`, so a click does not fire if the user pressed on the island and
/// released somewhere else.
final class IslandHostingView: HoverHostingView<IslandView> {
    var onClick: (() -> Void)?
    /// Height of the island strip, measured from the window's top edge.
    var islandStripHeight: CGFloat = 0

    /// Outline of the painted area in SwiftUI coordinates (y grows downward, origin
    /// at the window's top-left). Set by the controller together with the window frame.
    ///
    /// Needed because the window is a rectangle and the island is not. The shape
    /// already exists in `IslandLayout.silhouettePath`, and without this test the
    /// window's rectangle intercepts clicks over area where nothing is drawn. Two
    /// places make it obvious:
    ///
    ///  * **The fillets at the screen edge.** The window's top corners are NEVER
    ///    painted — the shape is concave there. The window is wider than the body by
    ///    `edgeRadius` on each side, and in that zone clicks on the app menu to the
    ///    left and the status icons to the right were going to the island. That was
    ///    a permanent irritant, not a momentary one.
    ///  * **The menu expanding.** The window jumps to its final size at once while
    ///    the mask catches up on a spring (`revealedHeight`), so for a fraction of a
    ///    second the window is wider than the drawing beneath it.
    ///
    /// `nil` turns the test off and the window behaves as an ordinary rectangle.
    var silhouette: CGPath?

    private func isInStrip(_ event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        return isFlipped
            ? point.y <= islandStripHeight
            : point.y >= bounds.height - islandStripHeight
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// A point in the outline's SwiftUI coordinates: y grows downward from the
    /// window's top edge. `NSHostingView` is flipped, but relying on that silently
    /// is not safe — the shape would end up upside down if it ever changed.
    private func silhouettePoint(_ pointInSelf: NSPoint) -> CGPoint {
        CGPoint(x: pointInSelf.x,
                y: isFlipped ? pointInSelf.y : bounds.height - pointInSelf.y)
    }

    /// Returns `nil` for points outside the painted shape, so the event goes where
    /// it belongs: the menu bar, the window under the island, wherever.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let silhouette else { return super.hitTest(point) }
        // `hitTest` is handed a point in the SUPERVIEW's coordinates, not its own.
        let local = superview.map { convert(point, from: $0) } ?? point
        guard bounds.contains(local) else { return super.hitTest(point) }
        guard silhouette.contains(silhouettePoint(local)) else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard isInStrip(event) else { super.mouseDown(with: event); return }
    }

    override func mouseUp(with event: NSEvent) {
        guard isInStrip(event) else { super.mouseUp(with: event); return }
        onClick?()
    }
}
