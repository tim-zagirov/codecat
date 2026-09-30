import XCTest
@testable import CodeCatCore

/// Screen rectangles are AppKit's: origin at the bottom-left, y up. A 14" MacBook's
/// visible frame (1512 × 982 less a 33 pt menu bar).
final class FloatingLayoutTests: XCTestCase {
    let visible = CGRect(x: 0, y: 0, width: 1512, height: 949)
    /// The default corner: bottom right.
    let corner = CGRect(x: 1300, y: 20, width: 176, height: 140)
    /// Upper left, with room below.
    let upperLeft = CGRect(x: 100, y: 500, width: 176, height: 140)

    /// 120 + 2 × 28 wide; 28 + (64 − 6 + 26) + 28 tall.
    func testTheCatWindowHoldsTheCatTheCapsuleAndTheBloom() {
        XCTAssertEqual(FloatingLayout.catWindowSize, CGSize(width: 176, height: 140))
        XCTAssertEqual(FloatingLayout.catCanvasRect, CGRect(x: 28, y: 28, width: 120, height: 64))
        // 22 pt in from the cat's canvas, its top 6 pt above the cat's feet (Figma 06).
        XCTAssertEqual(FloatingLayout.capsuleRect, CGRect(x: 50, y: 86, width: 96, height: 26))
    }

    /// The stored position keeps its meaning (spec §9): the old 128 pt canvas the cat
    /// was centred in. The cat's centre stays where it was — (88, 80) in the new
    /// window, (64, 64) in the old canvas.
    func testTheStoredAnchorPlacesTheCatWhereItWas() {
        XCTAssertEqual(FloatingLayout.catWindowOrigin(anchor: CGPoint(x: 1000, y: 300)), CGPoint(x: 976, y: 284))
        XCTAssertEqual(FloatingLayout.anchor(catWindowOrigin: CGPoint(x: 976, y: 284)), CGPoint(x: 1000, y: 300))
    }

    func testTheCapsuleOnScreen() {
        // x 1300 + 50; y 160 (the window's top) − 86 − 26.
        XCTAssertEqual(FloatingLayout.capsuleOnScreen(catWindow: corner), CGRect(x: 1350, y: 48, width: 96, height: 26))
    }

    /// Spec §9: the peek grows toward the screen's centre, so it never leaves the screen.
    func testThePeekGrowsTowardTheCentre() {
        XCTAssertTrue(FloatingLayout.growsLeft(catWindow: corner, visibleFrame: visible))
        // Right edges together: 1446 − 300; top edges together: 74 − 44.
        XCTAssertEqual(FloatingLayout.peekRect(catWindow: corner, visibleFrame: visible),
                       CGRect(x: 1146, y: 30, width: 300, height: 44))
        XCTAssertFalse(FloatingLayout.growsLeft(catWindow: upperLeft, visibleFrame: visible))
        XCTAssertEqual(FloatingLayout.peekRect(catWindow: upperLeft, visibleFrame: visible),
                       CGRect(x: 150, y: 510, width: 300, height: 44))
    }

    /// Decision 9: below the cat when the list fits below, otherwise above it, its
    /// bottom edge 6 pt under the cat's top.
    func testTheListOpensBelowWhenItFitsAndAboveWhenItDoesNot() {
        XCTAssertEqual(FloatingLayout.panelPlacement(height: 300, catWindow: upperLeft, visibleFrame: visible),
                       .init(rect: CGRect(x: 150, y: 254, width: 300, height: 300), isAbove: false))
        // In the corner 66 pt are left below (74 − 8); above, the panel starts at
        // 160 − 28 − 6 = 126.
        XCTAssertEqual(FloatingLayout.panelPlacement(height: 300, catWindow: corner, visibleFrame: visible),
                       .init(rect: CGRect(x: 1146, y: 126, width: 300, height: 300), isAbove: true))
    }

    /// A list taller than either room is cut to the larger one and scrolls.
    func testATallListIsCutToTheRoomThereIs() {
        // Below: 554 − 8 = 546; above: 949 − 8 − 606 = 335.
        XCTAssertEqual(FloatingLayout.panelPlacement(height: 2000, catWindow: upperLeft, visibleFrame: visible),
                       .init(rect: CGRect(x: 150, y: 8, width: 300, height: 546), isAbove: false))
    }
}
