import CoreGraphics

/// Where the floating cat's pieces go — spec §9, Figma 06: the cat stands on a
/// 96 × 26 black capsule whose top overlaps its feet by 6 pt; a peek widens the
/// capsule to 300 × 44 toward the screen's centre; the list is a 300 pt panel the cat
/// sits on. Two windows (decision 8): the cat's, fixed and draggable, and one panel
/// for the peek or the list, placed from the cat's window.
///
/// Rectangles inside the cat window use a top-left origin, like SwiftUI; rectangles
/// on screen are AppKit's, origin bottom-left, y up.
public enum FloatingLayout {
    /// The floating sprite's canvas: `SpriteScale.maxWidth` × `targetHeight`.
    public static let catCanvas = CGSize(width: 120, height: 64)
    /// Room around the drawing for the capsule's bloom (radius 10, so about 24 pt of
    /// fade, plus the lift on hover).
    public static let margin: CGFloat = 28
    public static let capsule = CGSize(width: 96, height: 26)
    public static let capsuleRadius: CGFloat = 13
    /// The capsule's left edge from the cat canvas's (Figma 06: 460 − 438).
    public static let capsuleInset: CGFloat = 22
    public static let feetOverlap: CGFloat = 6
    public static let peekCapsule = CGSize(width: 300, height: 44)
    public static let peekRadius: CGFloat = 22
    public static let panelWidth: CGFloat = 300
    public static let panelRadius: CGFloat = 22
    /// How close to the visible frame's edge a panel may come.
    public static let screenInset: CGFloat = 8

    public static var catWindowSize: CGSize {
        CGSize(width: catCanvas.width + 2 * margin,
               height: margin + catCanvas.height - feetOverlap + capsule.height + margin)
    }

    public static var catCanvasRect: CGRect {
        CGRect(origin: CGPoint(x: margin, y: margin), size: catCanvas)
    }

    public static var capsuleRect: CGRect {
        CGRect(x: margin + capsuleInset, y: margin + catCanvas.height - feetOverlap,
               width: capsule.width, height: capsule.height)
    }

    /// The stored position (`mascotPosition.v2`) is the origin of the 128 pt canvas the
    /// cat used to be centred in (`MascotLayout`). The new window is placed so the
    /// cat's centre stays where that canvas had it: no one's cat moves on the update.
    public static func catWindowOrigin(anchor: CGPoint) -> CGPoint {
        CGPoint(x: anchor.x + MascotLayout.canvasSize / 2 - catCentreInWindow.x,
                y: anchor.y + MascotLayout.canvasSize / 2 - catCentreInWindow.y)
    }

    public static func anchor(catWindowOrigin origin: CGPoint) -> CGPoint {
        CGPoint(x: origin.x - MascotLayout.canvasSize / 2 + catCentreInWindow.x,
                y: origin.y - MascotLayout.canvasSize / 2 + catCentreInWindow.y)
    }

    /// The cat canvas's centre in the cat window, y up.
    private static var catCentreInWindow: CGPoint {
        CGPoint(x: catCanvasRect.midX, y: catWindowSize.height - catCanvasRect.midY)
    }

    public static func capsuleOnScreen(catWindow: CGRect) -> CGRect {
        CGRect(x: catWindow.minX + capsuleRect.minX, y: catWindow.maxY - capsuleRect.maxY,
               width: capsule.width, height: capsule.height)
    }

    /// Toward the screen's centre: a cat in the right half grows its peek and list
    /// to the left.
    public static func growsLeft(catWindow: CGRect, visibleFrame: CGRect) -> Bool {
        capsuleOnScreen(catWindow: catWindow).midX > visibleFrame.midX
    }

    /// The peek capsule: its top at the resting capsule's top, so the cat stands on
    /// it, and one side on the resting capsule's side.
    public static func peekRect(catWindow: CGRect, visibleFrame: CGRect) -> CGRect {
        let rest = capsuleOnScreen(catWindow: catWindow)
        return CGRect(x: panelX(width: peekCapsule.width, rest: rest, catWindow: catWindow, visibleFrame: visibleFrame),
                      y: rest.maxY - peekCapsule.height, width: peekCapsule.width, height: peekCapsule.height)
    }

    public struct PanelPlacement: Equatable, Sendable {
        public let rect: CGRect
        /// Above the cat: there was no room below (decision 9).
        public let isAbove: Bool
        public init(rect: CGRect, isAbove: Bool) { self.rect = rect; self.isAbove = isAbove }
    }

    /// The list's panel for content `height` tall: below the cat — its top at the
    /// resting capsule's top, the cat sitting on its edge — when it fits there,
    /// otherwise above the cat with its bottom edge `feetOverlap` under the cat's top,
    /// whichever has more room when neither fits; cut to that room, the list scrolls.
    public static func panelPlacement(height: CGFloat, catWindow: CGRect, visibleFrame: CGRect) -> PanelPlacement {
        let rest = capsuleOnScreen(catWindow: catWindow)
        let x = panelX(width: panelWidth, rest: rest, catWindow: catWindow, visibleFrame: visibleFrame)
        let roomBelow = rest.maxY - visibleFrame.minY - screenInset
        let catTop = catWindow.maxY - catCanvasRect.minY
        let aboveBottom = catTop - feetOverlap
        let roomAbove = visibleFrame.maxY - screenInset - aboveBottom
        if height <= roomBelow || roomBelow >= roomAbove {
            let h = min(height, roomBelow)
            return PanelPlacement(rect: CGRect(x: x, y: rest.maxY - h, width: panelWidth, height: h), isAbove: false)
        }
        let h = min(height, roomAbove)
        return PanelPlacement(rect: CGRect(x: x, y: aboveBottom, width: panelWidth, height: h), isAbove: true)
    }

    private static func panelX(width: CGFloat, rest: CGRect, catWindow: CGRect, visibleFrame: CGRect) -> CGFloat {
        let x = growsLeft(catWindow: catWindow, visibleFrame: visibleFrame) ? rest.maxX - width : rest.minX
        return min(max(x, visibleFrame.minX + screenInset), visibleFrame.maxX - screenInset - width)
    }
}
