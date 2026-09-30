import CoreGraphics

/// The island's outline at one moment: the body's size (without the fillets) and
/// both radii — the four numbers the shape animates between states (spec §5.2).
public struct IslandBody: Hashable, Sendable {
    public var width: CGFloat
    public var height: CGFloat
    public var edgeRadius: CGFloat
    public var bottomRadius: CGFloat
    public init(width: CGFloat, height: CGFloat, edgeRadius: CGFloat, bottomRadius: CGFloat) {
        self.width = width; self.height = height; self.edgeRadius = edgeRadius; self.bottomRadius = bottomRadius
    }
}

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

    // MARK: 0.5 shapes (spec §4–§6)

    /// The expanded island and the peek: wider than the compact body so a card has
    /// room for a task line, still close to Apple's expanded Dynamic Island (371–408).
    public static let expandedWidth: CGFloat = 420
    /// Fillet and bottom radius grow with the shape; a 16 pt corner on a 487 pt panel
    /// looks sharp.
    public static let expandedEdgeRadius: CGFloat = 14
    /// The expanded island's and the peek's bottom corners: the cards' 12 pt corners,
    /// 12 pt in from the side, are concentric with 24 — spec §5.4.
    public static let expandedCornerRadius: CGFloat = 24
    /// The peek's height: the 32 pt compact band stays on top so the cat and the dots
    /// do not move, and the one reason line sits below it at y 42 — spec §6.2. One
    /// line is all a peek says; anything longer is the expanded list's job.
    public static let peekHeight: CGFloat = 78
    /// How much the island grows under the cursor before it opens.
    public static let inhaleGrowth = CGSize(width: 6, height: 4)

    // MARK: Bodies and canvases (spec §4.3, §5.2)

    /// The band the cat and the dots sit in when the island is open; the list starts
    /// below it. Four points more than the strip, so the first card clears the cat.
    public static let headerHeight: CGFloat = 36
    /// The open header's right side (§5.3, Figma 04 "Header right"): the 22 pt "•••"
    /// 20 pt in from the body's right edge, 10 pt after the dots.
    public static let headerTrailingInset: CGFloat = 20
    public static let settingsButtonSize: CGFloat = 22
    public static let headerButtonSpacing: CGFloat = 10

    /// How wide the header's dots may run: from the notch's right edge to the gap
    /// before "•••". Anything wider starts under the physical notch, where it cannot
    /// be seen (`RightWing.header`). 65.5 pt on a 185 pt notch.
    public static func headerDotsRoom(notchWidth: CGFloat) -> CGFloat {
        expandedWidth / 2 - headerTrailingInset - settingsButtonSize - headerButtonSpacing - notchWidth / 2
    }

    /// Air under the list, inside the body.
    public static let listBottomPadding: CGFloat = 12
    /// Room around the body for the bloom and the hover shadow (§4.1, §4.3), so
    /// neither is clipped by the window. A radius-14 bloom fades into the backdrop
    /// about 34 pt past the edge it is cast from (measured below the open island,
    /// whose window leaves it room): roughly 3 × 12 pt of blur plus its 2–3 pt
    /// offset. Below the body that is 36 + 2 → 40. Sideways it is cast from the wall,
    /// which lies `edgeRadius` inside the silhouette's rect: 36 − 10 = 26 → 28. The
    /// 24 pt this was cut the inhaled bloom off in a straight line 24 pt under it.
    public static let shadowMargin = CGSize(width: 28, height: 40)

    /// The body the island is drawn at in `presentation`. `compact` is the strip's
    /// size (both wings and the notch); `expandedHeight` the open list's full height.
    public static func body(for presentation: IslandPresentation, compact: CGSize,
                            expandedHeight: CGFloat) -> IslandBody {
        switch presentation {
        case .compact:
            return IslandBody(width: compact.width, height: compact.height,
                              edgeRadius: edgeRadius, bottomRadius: cornerRadius)
        case .inhaled:
            return IslandBody(width: compact.width + inhaleGrowth.width, height: compact.height + inhaleGrowth.height,
                              edgeRadius: edgeRadius, bottomRadius: cornerRadius)
        case .peek:
            return IslandBody(width: expandedWidth, height: peekHeight,
                              edgeRadius: expandedEdgeRadius, bottomRadius: expandedCornerRadius)
        case .expanded:
            return IslandBody(width: expandedWidth, height: expandedHeight,
                              edgeRadius: expandedEdgeRadius, bottomRadius: expandedCornerRadius)
        }
    }

    /// The tallest the open body may be: the visible frame less the menu bar and a
    /// margin, so the list scrolls instead of running off the screen (§5.2).
    public static func expandedMaxHeight(visibleHeight: CGFloat) -> CGFloat {
        max(0, visibleHeight - 32 - 24)
    }

    /// The open body's height for a list of `listHeight`: header, list, air — capped.
    public static func expandedHeight(listHeight: CGFloat, maxHeight: CGFloat) -> CGFloat {
        min(headerHeight + listHeight + listBottomPadding, maxHeight)
    }

    /// The largest body the open island can take — what its window is sized for.
    public static func openCanvasBody(maxHeight: CGFloat) -> IslandBody {
        IslandBody(width: expandedWidth, height: maxHeight,
                   edgeRadius: expandedEdgeRadius, bottomRadius: expandedCornerRadius)
    }

    /// The window for a state whose largest shape is `largest`: that body, its
    /// fillets and the shadow margins, centred on the island, top at the screen edge.
    /// AppKit coordinates (y up), like `island`.
    public static func canvasFrame(island: CGRect, largest: IslandBody) -> CGRect {
        let width = largest.width + 2 * largest.edgeRadius + 2 * shadowMargin.width
        let height = largest.height + shadowMargin.height
        return CGRect(x: island.midX - width / 2, y: island.maxY - height, width: width, height: height)
    }

    /// Where the silhouette (body plus fillets) sits in a canvas `canvasWidth` wide:
    /// centred, at the top. SwiftUI coordinates (y down) — the view and the hit test
    /// both use them.
    public static func silhouetteRect(canvasWidth: CGFloat, body: IslandBody) -> CGRect {
        let width = body.width + 2 * body.edgeRadius
        return CGRect(x: (canvasWidth - width) / 2, y: 0, width: width, height: body.height)
    }

    public static func silhouettePath(canvasWidth: CGFloat, body: IslandBody) -> CGPath {
        silhouettePath(in: silhouetteRect(canvasWidth: canvasWidth, body: body),
                       bottomRadius: body.bottomRadius, edgeRadius: body.edgeRadius)
    }

    public static func rimPath(canvasWidth: CGFloat, body: IslandBody) -> CGPath {
        rimPath(in: silhouetteRect(canvasWidth: canvasWidth, body: body),
                bottomRadius: body.bottomRadius, edgeRadius: body.edgeRadius)
    }

    /// A body of any size, centred on the notch, top at the screen edge.
    public static func bodyFrame(notch: CGRect, size: CGSize) -> CGRect {
        CGRect(x: notch.midX - size.width / 2, y: notch.maxY - size.height,
               width: size.width, height: size.height)
    }

    /// The rim light's path — spec §4.1. Open: it runs down the left wall from the
    /// fillet, around the bottom and up the right wall, and never along the top, which
    /// is the screen's edge. Inset so a centred stroke stays inside the silhouette.
    /// Same coordinates and clamping as `silhouettePath`.
    ///
    /// The bottom corners are concentric with the silhouette's: the same centres, the
    /// radius smaller by the inset. Drawn with the silhouette's own radius from the
    /// inset walls, the corner ran up to a third of a point closer to the edge than the
    /// walls did, and a 1.5 pt stroke showed it as a pinch at each corner.
    public static func rimPath(in rect: CGRect, bottomRadius: CGFloat, edgeRadius: CGFloat,
                               inset: CGFloat = 0.75) -> CGPath {
        let k: CGFloat = 0.5523
        let e = max(0, min(edgeRadius, min(rect.width / 2, rect.height)))
        let bodyWidth = rect.width - 2 * e
        let b = max(0, min(bottomRadius, min(bodyWidth / 2, rect.height - e)))
        let left = rect.minX + e + inset, right = rect.maxX - e - inset
        let top = rect.minY + e, bottom = rect.maxY - inset
        let r = max(0, b - inset)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: left, y: top))
        path.addLine(to: CGPoint(x: left, y: bottom - r))
        if r > 0 {
            path.addCurve(to: CGPoint(x: left + r, y: bottom),
                          control1: CGPoint(x: left, y: bottom - r + r * k),
                          control2: CGPoint(x: left + r - r * k, y: bottom))
        }
        path.addLine(to: CGPoint(x: right - r, y: bottom))
        if r > 0 {
            path.addCurve(to: CGPoint(x: right, y: bottom - r),
                          control1: CGPoint(x: right - r + r * k, y: bottom),
                          control2: CGPoint(x: right, y: bottom - r + r * k))
        }
        path.addLine(to: CGPoint(x: right, y: top))
        return path
    }

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
    ///
    /// `edgeRadius` is the fillet the shape is drawn with: the expanded island and the
    /// peek use `expandedEdgeRadius`, and a window sized for the compact 10 pt would
    /// clip their 14 pt fillets.
    public static func silhouetteFrame(island: CGRect,
                                       edgeRadius: CGFloat = IslandLayout.edgeRadius) -> CGRect {
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
                                   screenFrame: CGRect,
                                   edgeRadius: CGFloat = IslandLayout.edgeRadius) -> CGRect {
        let silhouette = silhouetteFrame(island: island, edgeRadius: edgeRadius)
        let available = island.maxY - screenFrame.minY
        let height = max(island.height, min(totalHeight, available))
        return CGRect(x: silhouette.minX, y: island.maxY - height,
                      width: silhouette.width, height: height)
    }
}
