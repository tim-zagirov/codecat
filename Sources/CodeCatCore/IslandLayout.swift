import CoreGraphics

/// Geometry of the "island" — the black slab that covers a display's physical
/// notch and extends into wings on either side.
///
/// Everything is derived from the two auxiliary areas macOS reports for a notched
/// display (`NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea`): the parts
/// of the menu bar to the left and right of the notch. The notch itself is the gap
/// between them, and the system offers no other way to learn its width.
///
/// There are no content rectangles here (the cat, the counter): `IslandView` lays
/// three known widths — left wing, notch, right wing — out in an ordinary `HStack`,
/// and a second coordinate system for that would earn nothing.
public enum IslandLayout {

    /// Padding from the sprite to the wing's edge on each side. The wings physically
    /// overlap the menu bar (the app menu on the left, other apps' status icons on
    /// the right), so they are cut to the sprite rather than made generously wide.
    public static let wingPadding: CGFloat = 8

    /// Wing width, the same on the left and the right.
    ///
    /// The wings deliberately do not adapt to the current skin. The cat is an object
    /// with bulk, the counter is a mark, and the only way to balance them is with
    /// geometry: equal wings put the whole black shape exactly at the notch's centre
    /// for every skin. The wing used to be sized from the sprite (48–72 pt on the
    /// left against a fixed 34 on the right), and the shape drifted 9.5 pt off centre.
    ///
    /// 72 = 56 (the widest sprite: LuizMelo `cat-4`, 28×16 px at the mandatory
    /// integer ×2) plus padding on both sides. Narrower skins simply get more air
    /// around the cat; the island's width does not change when the skin does, so
    /// nothing in the menu bar jumps.
    public static let wingWidth: CGFloat = 72

    /// The fillet where the island meets the top edge of the screen — concave,
    /// curving into the body.
    ///
    /// A right angle at that junction reads as a step: the black slab is placed
    /// against the edge rather than growing out of it. The fillet removes the step —
    /// the body's wall sweeps into the screen edge, and the corner of the wallpaper
    /// beside it picks up a matching curve. The arc is tangent to the edge above and
    /// to the body's wall at the side; swap those tangents and it bulges outward,
    /// giving the island shoulders.
    ///
    /// The slab grows by `edgeRadius` on each side to make room: the fillet lies
    /// outside the island's body and has nowhere to go without that margin. The body
    /// itself is unchanged — the wings stay 72 pt.
    public static let edgeRadius: CGFloat = 10

    /// Rounding on the island's and the menu's bottom corners. The island's top
    /// corners are square — they run into the screen's edge.
    ///
    /// 16 pt against an island height of 32 pt is half the height, meaning the bottom
    /// edge is rounded end to end with no straight run between the two arcs. That
    /// reads as a shape rather than a rectangle with softened corners; the physical
    /// notch beside it is curved to roughly the same degree, and a smaller radius
    /// next to it looks dry. More than half the height is impossible: the shape
    /// clamps the radius at that limit, so the difference would stop being visible.
    public static let cornerRadius: CGFloat = 16

    /// Whether the display has a notch. On one without, the top safe-area inset is
    /// zero; on a MacBook Pro's built-in display it equals the menu bar's height (32 pt).
    public static func hasNotch(safeAreaTop: CGFloat) -> Bool { safeAreaTop > 0 }

    /// The notch — the gap between the auxiliary areas. `nil` if the system did not
    /// report them (a display with no notch) or if there is no positive width between them.
    public static func notchRect(auxLeft: CGRect?, auxRight: CGRect?) -> CGRect? {
        guard let auxLeft, let auxRight else { return nil }
        let width = auxRight.minX - auxLeft.maxX
        guard width > 0, auxLeft.height > 0 else { return nil }
        return CGRect(x: auxLeft.maxX, y: auxLeft.minY, width: width, height: auxLeft.height)
    }

    /// The whole slab: the notch plus two equal wings. Its height equals the notch's —
    /// the island does not extend past the menu bar.
    public static func islandFrame(notch: CGRect) -> CGRect {
        CGRect(x: notch.minX - wingWidth,
               y: notch.minY,
               width: 2 * wingWidth + notch.width,
               height: notch.height)
    }

    /// The island window's rectangle: the body plus room for a fillet on each side.
    /// Kept apart from `islandFrame` because they are different quantities:
    /// `islandFrame` is what the content is laid out against (wing, notch, wing), and
    /// this is what has to be painted.
    public static func silhouetteFrame(island: CGRect) -> CGRect {
        island.insetBy(dx: -edgeRadius, dy: 0)
    }

    /// The island's outline in SwiftUI coordinates (y grows downward, origin at the
    /// top-left): concave fillets against the screen edge at the top, rounded corners
    /// at the bottom.
    ///
    /// `rect` is the whole window rectangle (`silhouetteFrame`) — the body plus the
    /// fillets at its edges. An `edgeRadius` of zero (or one that will not fit)
    /// simply yields square top corners; the shape stays correct.
    ///
    /// The arcs are cubic Béziers with the 0.5523 constant: a quadratic curve is off
    /// by about 5% on a quarter circle, and that would be visible where it meets the
    /// notch's real arc.
    public static func silhouettePath(in rect: CGRect,
                                      bottomRadius: CGFloat,
                                      edgeRadius: CGFloat = IslandLayout.edgeRadius) -> CGPath {
        let k: CGFloat = 0.5523
        // Clamped so the shape cannot turn itself inside out on a narrow or short
        // island: the fillet is no wider than half the width and no taller than the
        // island, and the bottom radius no more than half the remaining body and
        // whatever height is left after the fillet. Otherwise the body's vertical wall
        // would run upward from the bottom.
        let e = max(0, min(edgeRadius, min(rect.width / 2, rect.height)))
        let bodyWidth = rect.width - 2 * e
        let b = max(0, min(bottomRadius, min(bodyWidth / 2, rect.height - e)))
        let left = rect.minX, right = rect.maxX, top = rect.minY, bottom = rect.maxY
        let bodyLeft = left + e, bodyRight = right - e

        let path = CGMutablePath()
        path.move(to: CGPoint(x: left, y: top))
        path.addLine(to: CGPoint(x: right, y: top))
        // Right fillet: the arc is tangent to the screen edge above and to the body's
        // wall at the side. Those tangents and not the reverse — with the control
        // points swapped the arc bulges outward, and instead of flowing into the edge
        // the island grows shoulders. Confirmed by rendering it; they look like ears.
        if e > 0 {
            path.addCurve(to: CGPoint(x: bodyRight, y: top + e),
                          control1: CGPoint(x: right - e * k, y: top),
                          control2: CGPoint(x: bodyRight, y: top + e - e * k))
        }
        path.addLine(to: CGPoint(x: bodyRight, y: bottom - b))
        if b > 0 {
            path.addCurve(to: CGPoint(x: bodyRight - b, y: bottom),
                          control1: CGPoint(x: bodyRight, y: bottom - b + b * k),
                          control2: CGPoint(x: bodyRight - b + b * k, y: bottom))
        }
        path.addLine(to: CGPoint(x: bodyLeft + b, y: bottom))
        if b > 0 {
            path.addCurve(to: CGPoint(x: bodyLeft, y: bottom - b),
                          control1: CGPoint(x: bodyLeft + b - b * k, y: bottom),
                          control2: CGPoint(x: bodyLeft, y: bottom - b + b * k))
        }
        path.addLine(to: CGPoint(x: bodyLeft, y: top + e))
        // Left fillet, mirroring the right.
        if e > 0 {
            path.addCurve(to: CGPoint(x: left, y: top),
                          control1: CGPoint(x: bodyLeft, y: top + e - e * k),
                          control2: CGPoint(x: left + e * k, y: top))
        }
        path.closeSubpath()
        return path
    }

    /// The island window's frame at a full height of `totalHeight` (the island strip
    /// plus the expanded menu).
    ///
    /// The top edge never moves: the window grows downward from the screen's edge.
    /// The width is always the silhouette's, because the island and the menu are now
    /// one shape in one window; the menu has no width of its own any more, and so
    /// there is no ledge at the join that used to need hiding.
    ///
    /// The height is clamped below by the island strip (the window cannot be shorter)
    /// and above by the bottom of the screen.
    public static func windowFrame(island: CGRect,
                                   totalHeight: CGFloat,
                                   screenFrame: CGRect) -> CGRect {
        let silhouette = silhouetteFrame(island: island)
        let available = island.maxY - screenFrame.minY
        let height = max(island.height, min(totalHeight, available))
        return CGRect(x: silhouette.minX, y: island.maxY - height,
                      width: silhouette.width, height: height)
    }
}
