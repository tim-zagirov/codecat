import CoreGraphics

/// Geometry of the floating mascot panel.
///
/// The panel window is deliberately *larger* than the cat drawing. The window has
/// no shadow and a clear background, so its edge is invisible — but it still clips:
/// anything the animation swings past the frame is cut off mid-stroke. With the
/// window sized exactly like the drawing (both were 96pt), the swishing tail was
/// sliced off at the bottom-right, which is what users saw as "the tail gets
/// masked".
///
/// Measured extremes of `CatView` across every state and both animation phases
/// (rendered offscreen, bounding box of non-transparent pixels): the drawing
/// reaches 55.2pt from its centre — the tail tip while working, and the badge for
/// a three-digit session count — so it needs a canvas of ~111pt. `canvasSize`
/// keeps a margin beyond that for the intermediate frames and future tweaks.
public enum MascotLayout {
    /// The coordinate space `CatView` is drawn in — unchanged, so the cat keeps
    /// its familiar on-screen size.
    public static let drawingSize: CGFloat = 96

    /// The panel window (and the SwiftUI canvas inside it). Larger than the
    /// drawing so animations have room to overshoot without being clipped.
    public static let canvasSize: CGFloat = 128

    /// Transparent slack on each side of the drawing.
    public static var margin: CGFloat { (canvasSize - drawingSize) / 2 }

    /// Converts a window origin saved when the panel was `fromCanvas` points wide
    /// into one for a `toCanvas`-wide panel that leaves the cat visually put.
    /// The cat is centred in its window, so the origin moves out by half the growth.
    public static func migratedOrigin(_ saved: CGPoint,
                                      fromCanvas: CGFloat,
                                      toCanvas: CGFloat) -> CGPoint {
        let shift = (toCanvas - fromCanvas) / 2
        return CGPoint(x: saved.x - shift, y: saved.y - shift)
    }

    /// Bottom-right corner placement. `inset` is measured from the *drawing*, not
    /// from the invisible window edge, so the transparent margin does not push the
    /// cat away from the corner.
    public static func defaultOrigin(visibleFrame: CGRect, inset: CGFloat) -> CGPoint {
        CGPoint(x: visibleFrame.maxX - inset - drawingSize - margin,
                y: visibleFrame.minY + inset - margin)
    }

    /// The panel size used by builds before the clipping fix. Positions they wrote
    /// carry no canvas of their own, so they are read against this.
    public static let legacyCanvasSize: CGFloat = 96

    /// Encodes a window origin for persistence, tagged with the canvas it belongs
    /// to. Storing the canvas is what lets a later size change migrate itself.
    public static func storedValue(for origin: CGPoint) -> [Double] {
        [Double(origin.x), Double(origin.y), Double(canvasSize)]
    }

    /// Decodes a persisted position, migrating it to the current canvas.
    /// `current` is a `[x, y, canvas]` triple; `legacy` is the bare `[x, y]` pair
    /// written by builds from before the panel grew. Returns `nil` when neither
    /// holds a usable value, which means "place the cat at its default corner".
    public static func storedOrigin(current: [Double]?, legacy: [Double]?) -> CGPoint? {
        if let current, current.count == 3 {
            let canvas = CGFloat(current[2])
            if canvas > 0 {
                return migratedOrigin(CGPoint(x: current[0], y: current[1]),
                                      fromCanvas: canvas, toCanvas: canvasSize)
            }
        }
        if let legacy, legacy.count == 2 {
            return migratedOrigin(CGPoint(x: legacy[0], y: legacy[1]),
                                  fromCanvas: legacyCanvasSize, toCanvas: canvasSize)
        }
        return nil
    }

    /// Whether a panel placed at `origin` would be reachable on any of the given
    /// screen frames. Guards against a position remembered from a display that is
    /// no longer connected.
    public static func isOnScreen(origin: CGPoint, screens: [CGRect]) -> Bool {
        let rect = CGRect(origin: origin, size: CGSize(width: canvasSize, height: canvasSize))
        return screens.contains { $0.intersects(rect) }
    }
}
