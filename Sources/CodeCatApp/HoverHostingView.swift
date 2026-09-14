import AppKit
import SwiftUI

/// Where the cursor is, in the hosting view's own coordinates — origin at the
/// top-left, the frame SwiftUI's `.global` coordinate space uses inside an
/// `NSHostingView` — or `nil` while it is outside the window.
///
/// SwiftUI's `.onHover` and `.onContinuousHover` report nothing in a window that is
/// not key, and the island's window is deliberately never made key by hover: a key
/// panel would take keystrokes away from the terminal the user is typing in while
/// the mouse wanders onto the notch. An `.activeAlways` tracking area on the AppKit
/// host does fire in that situation, so the host publishes the position here and
/// `onHoverRegion` (`MenuStyle.swift`) decides "hovered" from each view's own frame.
/// The floating details panel uses the same path even though it is key, so the two
/// surfaces cannot drift apart.
final class PointerTracker: ObservableObject {
    @Published var location: CGPoint?
}

/// An `NSHostingView` that reports when the cursor enters and leaves, and publishes
/// where it is in between (`pointer`).
///
/// Hover is caught with `NSTrackingArea` rather than SwiftUI's hover for two
/// reasons: the island's window must not activate and steal focus, and the event
/// is needed even when the app is not active (`.activeAlways`). Mouse-moved events
/// reach a tracking area's owner only with `.mouseMoved` in its options AND
/// `acceptsMouseMovedEvents` on the window; both panels set the flag.
class HoverHostingView<Content: View>: NSHostingView<Content> {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    /// Set by the controller before the view is shown, and handed to the SwiftUI
    /// content as an environment object by the same controller.
    var pointer = PointerTracker()
    /// Only this view's own area is replaced on update: `NSHostingView` registers
    /// tracking areas of its own for SwiftUI, and those are not ours to remove.
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        // `.inVisibleRect` avoids recomputing the rectangle every time the window
        // resizes — and it resizes whenever the skin changes or the menu opens.
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    /// Puts the point into the top-left-origin coordinates SwiftUI's `.global` space
    /// reports frames in — which for a flipped `NSHostingView` is the converted point
    /// as is. The flip is not assumed silently, the same care `silhouettePoint` takes.
    ///
    /// An unchanged position is not reassigned: every mouse move in a key panel
    /// reaches here twice (once down the responder chain, once from the tracking
    /// area), and each assignment invalidates every hover region.
    private func publish(_ event: NSEvent) {
        let inSelf = convert(event.locationInWindow, from: nil)
        let point = CGPoint(x: inSelf.x,
                            y: isFlipped ? inSelf.y : bounds.height - inSelf.y)
        if pointer.location != point { pointer.location = point }
    }

    override func mouseEntered(with event: NSEvent) {
        publish(event)
        onEnter?()
    }

    override func mouseMoved(with event: NSEvent) {
        publish(event)
    }

    override func mouseExited(with event: NSEvent) {
        pointer.location = nil
        onExit?()
    }
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
    /// Called when Escape is pressed. Wired to close the full menu. Only the full
    /// menu makes the panel key, so `keyDown` reaches this view only then — Escape
    /// can close the full menu and nothing else.
    var onEscape: (() -> Void)?
    /// Height of the island strip, measured from the window's top edge.
    var islandStripHeight: CGFloat = 0
    /// Whether a menu is currently revealed under the strip. Set by the controller
    /// (in `applyFrame`) on every menu transition. When it is `false` the window is
    /// the bare strip, and S15 lets clicks on it fall through to the menu bar
    /// beneath — see `hitTest`.
    var menuIsOpen: Bool = false

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
        isInStripRegion(convert(event.locationInWindow, from: nil))
    }

    /// Whether a point in the view's own coordinates lies within the island strip
    /// (the top `islandStripHeight`, whichever way the view is flipped). When the
    /// menu is closed the whole window is the strip, so this is effectively "inside
    /// the window".
    private func isInStripRegion(_ pointInSelf: NSPoint) -> Bool {
        isFlipped
            ? pointInSelf.y <= islandStripHeight
            : pointInSelf.y >= bounds.height - islandStripHeight
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Lets the view become first responder so `keyDown` reaches it: the controller
    /// makes it first responder only while the full menu is key, which is what puts
    /// Escape (below) in front of the view instead of letting AppKit beep at it.
    override var acceptsFirstResponder: Bool { true }

    /// Escape (keyCode 53) closes the full menu; every other key falls through to the
    /// SwiftUI content so the toggles and buttons keep their own key handling.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }

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
        // S15: with the menu closed the window is the bare strip, and the strip sits
        // on top of the menu bar. Pass clicks on it straight through to the menu
        // titles beneath — the app menu under the left wing, the status icons under
        // the right — instead of swallowing them into a window the user is not
        // interacting with. Hover is unaffected: it rides the `.activeAlways`
        // tracking area, which AppKit evaluates from the cursor's geometry, not from
        // `hitTest`, so the dwell still opens the menu. Only the redundant
        // click-to-open is given up while closed; once a menu is open (`menuIsOpen`)
        // the strip is live again, so clicking it expands or dismisses as before.
        if !menuIsOpen, isInStripRegion(local) { return nil }
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
