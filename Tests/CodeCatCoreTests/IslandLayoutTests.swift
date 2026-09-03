import XCTest
import CoreGraphics
@testable import CodeCatCore

/// Every number here is measured on the target machine (MacBook Pro 16"), not
/// rounded by eye: a 1728x1117 pt screen, a 32 pt menu bar, and a 185 pt notch
/// spanning x ∈ [771, 956].
final class IslandLayoutTests: XCTestCase {

    private let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    private let auxLeft = CGRect(x: 0, y: 1085, width: 771, height: 32)
    private let auxRight = CGRect(x: 956, y: 1085, width: 772, height: 32)

    // MARK: - The notch

    func testNotchIsTheGapBetweenTheTwoAuxiliaryAreas() {
        let notch = IslandLayout.notchRect(auxLeft: auxLeft, auxRight: auxRight)
        XCTAssertEqual(notch, CGRect(x: 771, y: 1085, width: 185, height: 32))
    }

    /// A display without a notch reports no auxiliary areas at all.
    func testNoNotchWhenAuxiliaryAreasAreMissing() {
        XCTAssertNil(IslandLayout.notchRect(auxLeft: nil, auxRight: nil))
        XCTAssertNil(IslandLayout.notchRect(auxLeft: auxLeft, auxRight: nil))
        XCTAssertNil(IslandLayout.notchRect(auxLeft: nil, auxRight: auxRight))
    }

    /// The areas met or overlapped — there is no gap between them, so the island has
    /// nothing to hold on to. Zero width is not a notch either.
    func testNoNotchWhenAreasTouchOrOverlap() {
        let touching = CGRect(x: 771, y: 1085, width: 957, height: 32)
        XCTAssertNil(IslandLayout.notchRect(auxLeft: auxLeft, auxRight: touching))
        let overlapping = CGRect(x: 700, y: 1085, width: 1028, height: 32)
        XCTAssertNil(IslandLayout.notchRect(auxLeft: auxLeft, auxRight: overlapping))
    }

    func testHasNotchFollowsTheSafeAreaInset() {
        XCTAssertTrue(IslandLayout.hasNotch(safeAreaTop: 32))
        XCTAssertFalse(IslandLayout.hasNotch(safeAreaTop: 0))
    }

    // MARK: - Wings

    /// The main compositional requirement: the black shape must sit exactly at the
    /// notch's centre. The cat is an object with bulk, the counter is a mark, and they
    /// can only be balanced with geometry — so the wings are equal on both sides
    /// regardless of how wide the current skin's sprite is.
    func testWingsAreSymmetricAroundTheNotch() {
        let notch = CGRect(x: 771, y: 1085, width: 185, height: 32)
        let island = IslandLayout.islandFrame(notch: notch)
        XCTAssertEqual(notch.minX - island.minX, island.maxX - notch.maxX, accuracy: 0.001)
        XCTAssertEqual(island.midX, notch.midX, accuracy: 0.001)
    }

    /// The wings grow outward from the notch's edges: the notch itself stays exactly
    /// where it was, and neither wing encroaches on it.
    func testIslandGrowsOutwardWithoutEatingIntoTheNotch() {
        let notch = CGRect(x: 771, y: 1085, width: 185, height: 32)
        let island = IslandLayout.islandFrame(notch: notch)
        let wing = IslandLayout.wingWidth
        XCTAssertEqual(island, CGRect(x: 771 - wing, y: 1085, width: 2 * wing + 185, height: 32))
        XCTAssertEqual(island.height, notch.height, accuracy: 0.001)
    }

    /// The wing is sized for the widest skin — LuizMelo `cat-4`, 28×16 px, which at the
    /// mandatory integer ×2 gives 56 pt — and leaves padding on both sides. Narrower is
    /// not possible: the cat would run into the slab's edge.
    func testWingFitsTheWidestSkinWithPaddingOnBothSides() {
        XCTAssertGreaterThanOrEqual(IslandLayout.wingWidth, 56 + 2 * IslandLayout.wingPadding)
    }

    // MARK: - The window: island and menu are one shape

    /// The window's top edge does not move: the shape grows downward from the screen's
    /// edge rather than relocating. That is what "slides out of the island" means.
    func testWindowGrowsDownwardsAndKeepsItsTopEdgeAtTheScreenEdge() {
        let island = CGRect(x: 701, y: 1085, width: 329, height: 32)
        for total in [32.0, 120.0, 400.0] as [CGFloat] {
            let frame = IslandLayout.windowFrame(island: island, totalHeight: total,
                                                 screenFrame: screen)
            XCTAssertEqual(frame.maxY, island.maxY, accuracy: 0.001, "height \(total)")
            XCTAssertEqual(frame.height, total, accuracy: 0.001, "height \(total)")
        }
    }

    /// The window is always one width — the silhouette's. The menu has no width of its
    /// own any more, and so there is no ledge at the join that used to need hiding.
    func testWindowIsAlwaysAsWideAsTheSilhouette() {
        for width in [281.0, 329.0, 400.0] as [CGFloat] {
            let island = CGRect(x: 701, y: 1085, width: width, height: 32)
            let frame = IslandLayout.windowFrame(island: island, totalHeight: 200,
                                                 screenFrame: screen)
            XCTAssertEqual(frame.width, IslandLayout.silhouetteFrame(island: island).width,
                           accuracy: 0.001, "width \(width)")
            XCTAssertEqual(frame.midX, island.midX, accuracy: 0.001)
        }
    }

    /// The window never shrinks below the island strip: that is its own height at rest.
    func testWindowNeverShrinksBelowTheIslandStrip() {
        let island = CGRect(x: 701, y: 1085, width: 329, height: 32)
        let frame = IslandLayout.windowFrame(island: island, totalHeight: 0, screenFrame: screen)
        XCTAssertEqual(frame.height, island.height, accuracy: 0.001)
    }

    /// A menu taller than the screen must not run off the bottom edge.
    func testWindowNeverGoesBelowTheScreen() {
        let island = CGRect(x: 701, y: 1085, width: 329, height: 32)
        let frame = IslandLayout.windowFrame(island: island, totalHeight: 4000,
                                             screenFrame: screen)
        XCTAssertGreaterThanOrEqual(frame.minY, screen.minY)
    }

    // MARK: - Numbers from the spec

    /// The wing's width is a number from the visual specification; in the other tests
    /// it appears only as a derived value, so it is pinned explicitly here.
    func testWingWidthMatchesSpec() {
        XCTAssertEqual(IslandLayout.wingWidth, 72)
    }

    // MARK: - The silhouette: fillets at the screen edge

    /// The fillets lie outside the body, so the window is wider — but by exactly them,
    /// and the centre does not move: the island has to stay symmetric about the notch.
    func testSilhouetteFrameAddsTheFilletMarginsOnBothSidesWithoutMovingTheCentre() {
        let island = CGRect(x: 100, y: 1085, width: 329, height: 32)
        let silhouette = IslandLayout.silhouetteFrame(island: island)
        XCTAssertEqual(silhouette.width, island.width + 2 * IslandLayout.edgeRadius)
        XCTAssertEqual(silhouette.height, island.height)
        XCTAssertEqual(silhouette.midX, island.midX)
        XCTAssertEqual(silhouette.minY, island.minY)
    }

    /// The shape touches all four sides of its rectangle: full width at the top (where
    /// it meets the screen's edge) and the body's width at the bottom.
    func testSilhouetteFillsTheWholeWidthAtTheScreenEdge() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 32)
        let path = IslandLayout.silhouettePath(in: rect, bottomRadius: 16)
        XCTAssertEqual(path.boundingBox.minX, rect.minX, accuracy: 0.01)
        XCTAssertEqual(path.boundingBox.maxX, rect.maxX, accuracy: 0.01)
        XCTAssertEqual(path.boundingBox.minY, rect.minY, accuracy: 0.01)
        XCTAssertEqual(path.boundingBox.maxY, rect.maxY, accuracy: 0.01)
    }

    /// The essence of a fillet is which way it curves. The correct one is concave: at
    /// the body's wall the black spreads outward, while the outer corner at the edge
    /// stays wallpaper. Swap the tangents and the arc bulges outward, filling that
    /// outer corner — those are the "ears", and they are what not to do.
    func testTheFilletCurvesInwardAndLeavesTheOuterCornerToTheWallpaper() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 32)
        let e = IslandLayout.edgeRadius
        let path = IslandLayout.silhouettePath(in: rect, bottomRadius: 16)

        XCTAssertFalse(path.contains(CGPoint(x: 0.5, y: 0.5)),
                       "the outer corner on the left is wallpaper, not a shoulder")
        XCTAssertFalse(path.contains(CGPoint(x: rect.maxX - 0.5, y: 0.5)),
                       "and on the right too")
        XCTAssertTrue(path.contains(CGPoint(x: e - 1, y: 1)),
                      "at the body's wall the fillet is filled — black flows out of the edge")
        XCTAssertTrue(path.contains(CGPoint(x: rect.maxX - e + 1, y: 1)))
        XCTAssertTrue(path.contains(CGPoint(x: rect.midX, y: e)), "the body is where it should be")
    }

    /// The fillet fills area **outside** the body: a point just left of the body, right
    /// at the edge, is black with a fillet and wallpaper without one. That shows the
    /// widening comes from the fillet and not from something else.
    func testTheFilletFillsSpaceOutsideTheBodyThatIsOtherwiseWallpaper() {
        let body = CGRect(x: 0, y: 0, width: 200, height: 32)
        let spot = CGPoint(x: body.minX - 1, y: body.minY + 1)
        let withFillet = IslandLayout.silhouettePath(
            in: IslandLayout.silhouetteFrame(island: body), bottomRadius: 16)
        let square = IslandLayout.silhouettePath(in: body, bottomRadius: 16, edgeRadius: 0)
        XCTAssertTrue(withFillet.contains(spot))
        XCTAssertFalse(square.contains(spot))
    }

    /// A zero fillet radius is the old shape with square top corners. Needed both as
    /// the degradation on a narrow island and so the difference is testable.
    func testZeroEdgeRadiusLeavesSquareTopCorners() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 32)
        let path = IslandLayout.silhouettePath(in: rect, bottomRadius: 16, edgeRadius: 0)
        XCTAssertTrue(path.contains(CGPoint(x: 0.5, y: 10)), "square corner — filled")
    }

    /// Radii that do not fit the rectangle are clamped rather than turning the shape
    /// inside out: the island is narrow on a small notch.
    func testOversizedRadiiAreClampedAndTheShapeStaysInsideItsRect() {
        let rect = CGRect(x: 0, y: 0, width: 20, height: 8)
        let path = IslandLayout.silhouettePath(in: rect, bottomRadius: 999, edgeRadius: 999)
        XCTAssertTrue(rect.insetBy(dx: -0.01, dy: -0.01).contains(path.boundingBox))
        XCTAssertFalse(path.isEmpty)
    }
}

/// The outline as a click hit test (see `IslandHostingView.hitTest`).
///
/// The window is a rectangle and the island is not, and without this test the
/// window's rectangle intercepted clicks where nothing was drawn.
final class IslandSilhouetteHitTests: XCTestCase {

    private let rect = CGRect(x: 0, y: 0, width: 200, height: 120)
    private var path: CGPath {
        IslandLayout.silhouettePath(in: rect, bottomRadius: 16)
    }

    /// The main zone: the window's top corners are concave with a fillet and are NEVER
    /// filled. This is exactly where menu-bar clicks were going to the island.
    func testTopCornersAreOutsideSoMenuBarClicksPassThrough() {
        let e = IslandLayout.edgeRadius
        XCTAssertFalse(path.contains(CGPoint(x: 1, y: 1)),
                       "the window's top-left corner is fillet — empty there")
        XCTAssertFalse(path.contains(CGPoint(x: rect.maxX - 1, y: 1)),
                       "the window's top-right corner is fillet — empty there")
        XCTAssertFalse(path.contains(CGPoint(x: 2, y: e - 2)),
                       "the whole concave zone on the left is clear")
        XCTAssertFalse(path.contains(CGPoint(x: rect.maxX - 2, y: e - 2)),
                       "and on the right too")
    }

    /// The other half: clicks on the body itself must pass through, or the check would
    /// break the island instead of fixing it.
    func testBodyIsInsideSoTheIslandStillTakesClicks() {
        XCTAssertTrue(path.contains(CGPoint(x: rect.midX, y: 2)),
                      "the middle of the top edge is the body")
        XCTAssertTrue(path.contains(CGPoint(x: rect.midX, y: rect.midY)))
        XCTAssertTrue(path.contains(CGPoint(x: IslandLayout.edgeRadius + 2, y: rect.midY)),
                      "the body's left wall, right past the fillet")
    }

    /// The bottom corners are rounded — empty there too.
    func testBottomCornersAreOutside() {
        let e = IslandLayout.edgeRadius
        XCTAssertFalse(path.contains(CGPoint(x: e + 1, y: rect.maxY - 1)),
                       "the bottom-left corner is rounded")
        XCTAssertFalse(path.contains(CGPoint(x: rect.maxX - e - 1, y: rect.maxY - 1)),
                       "the bottom-right corner is rounded")
        XCTAssertTrue(path.contains(CGPoint(x: rect.midX, y: rect.maxY - 1)),
                      "but the middle of the bottom edge is filled")
    }

    /// While the menu is closed the window is one island strip tall: there is nothing
    /// to click below the strip, and the outline has to reflect that.
    func testShortWindowHasNoAreaBelowTheStrip() {
        let strip = CGRect(x: 0, y: 0, width: 200, height: 32)
        let p = IslandLayout.silhouettePath(in: strip, bottomRadius: 16)
        XCTAssertTrue(p.contains(CGPoint(x: strip.midX, y: 16)))
        XCTAssertFalse(p.contains(CGPoint(x: strip.midX, y: 40)),
                       "there is no shape past the window's bottom edge")
    }
}
