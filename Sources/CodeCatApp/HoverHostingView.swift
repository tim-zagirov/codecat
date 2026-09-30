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
/// `onHoverRegion` (`IslandPalette.swift`) decides "hovered" from each view's own
/// frame. The floating cat's panel uses the same path, so the two surfaces cannot
/// drift apart.
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
    /// Every position the tracking area reports, in the same top-left coordinates as
    /// `pointer`, and `nil` when the cursor leaves the window. The island decides
    /// "inside" from this against its silhouette: its window is larger than the shape.
    var onPointer: ((CGPoint?) -> Void)?
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
    /// as is. The flip is not assumed silently, the same care
    /// `IslandHostingView.canvasPoint` takes.
    ///
    /// An unchanged position is not reassigned: every mouse move in a key panel
    /// reaches here twice (once down the responder chain, once from the tracking
    /// area), and each assignment invalidates every hover region.
    private func publish(_ event: NSEvent) {
        let inSelf = convert(event.locationInWindow, from: nil)
        let point = CGPoint(x: inSelf.x,
                            y: isFlipped ? inSelf.y : bounds.height - inSelf.y)
        if pointer.location != point { pointer.location = point }
        onPointer?(point)
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
        onPointer?(nil)
        onExit?()
    }
}

/// A host whose panel answers Escape (keyCode 53) — it reaches `keyDown` only while
/// the panel is key, after a click inside, so it never takes a key from anyone else.
class EscapeHostingView<Content: View>: HoverHostingView<Content> {
    var onEscape: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// So the owner can make this view first responder when the panel becomes key,
    /// which is what puts Escape in front of it.
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }
}

/// The island's host view: clicks are judged against the painted shape, and Escape
/// goes to the controller.
final class IslandHostingView: EscapeHostingView<IslandView> {
    /// The outline of the shape the island is heading to, in the view's top-left
    /// coordinates (SwiftUI's). Set by the controller together with the window frame,
    /// from one entry point, so the two never disagree.
    ///
    /// The window is a rectangle much larger than the island — room to inhale, to
    /// open, to cast shadows. The controller tests the cursor against this outline to
    /// decide hover and whether the window takes clicks at all
    /// (`IslandController.updateClickTarget`); here it only keeps the views inside
    /// the window from answering a click outside the shape.
    var silhouette: CGPath?

    /// S15: the closed island passes every click straight through to the menu bar
    /// under it — its wings cover the app menu and other apps' status items, and a
    /// click there is meant for them. Hover still works: it rides the tracking area,
    /// which AppKit drives from the cursor's position, not from `hitTest`.
    ///
    /// This alone does not hand the click on — the window has already received it.
    /// What lets it through is the panel's `ignoresMouseEvents`, which the controller
    /// sets; this flag only keeps every view inside the closed island from answering.
    var clickThrough = true

    /// A point in the view's own coordinates, in the top-left space the silhouette is
    /// drawn in. `NSHostingView` is flipped, but relying on that silently would put
    /// the shape upside down the day it is not.
    func canvasPoint(_ pointInSelf: NSPoint) -> CGPoint {
        CGPoint(x: pointInSelf.x, y: isFlipped ? pointInSelf.y : bounds.height - pointInSelf.y)
    }

    /// `nil` for every point the island does not paint, and for every point while it
    /// is closed, so no view inside answers there. That only picks the view: the
    /// window has the click already, and passing it on to what lies under the window
    /// is `ignoresMouseEvents`' job (`IslandController.updateClickTarget`).
    override func hitTest(_ point: NSPoint) -> NSView? {
        // `hitTest` is handed a point in the SUPERVIEW's coordinates.
        let local = superview.map { convert(point, from: $0) } ?? point
        guard bounds.contains(local) else { return super.hitTest(point) }
        guard !clickThrough, let silhouette, silhouette.contains(canvasPoint(local)) else { return nil }
        return super.hitTest(point)
    }
}
