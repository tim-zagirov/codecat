import XCTest
@testable import CodeCatCore

final class SpriteScaleTests: XCTestCase {

    /// The three packs actually shipped, measured from their pixels: LuizMelo's cats
    /// are 27x14, Elthen's is 18x12, mxmaze's fills its whole 16x16 tile.
    func testTheThreePacksLandOnComparableHeights() {
        XCTAssertEqual(SpriteScale.factor(boundsWidth: 27, boundsHeight: 14), 4)
        XCTAssertEqual(SpriteScale.factor(boundsWidth: 18, boundsHeight: 12), 5)
        XCTAssertEqual(SpriteScale.factor(boundsWidth: 16, boundsHeight: 16), 4)
    }

    /// The whole point of the rule: on-screen heights must not drift apart the way
    /// they did under "normalise the larger side" (which gave 42pt against 96pt).
    func testOnScreenHeightsStayWithinAFewPointsOfEachOther() {
        let heights = [(27, 14), (18, 12), (16, 16)].map { w, h in
            h * SpriteScale.factor(boundsWidth: w, boundsHeight: h)
        }
        XCTAssertEqual(heights, [56, 60, 64])
        XCTAssertLessThanOrEqual(heights.max()! - heights.min()!, 12)
    }

    func testNothingEverExceedsTheCanvasWidth() {
        for w in 1...200 {
            for h in 1...200 {
                let s = SpriteScale.factor(boundsWidth: w, boundsHeight: h)
                XCTAssertGreaterThanOrEqual(s, 1, "\(w)x\(h)")
                if w * s > SpriteScale.maxWidth {
                    // Only a sprite too wide to fit even at 1x may exceed the limit;
                    // there is no smaller integer scale to fall back to.
                    XCTAssertEqual(s, 1, "\(w)x\(h) вышел за предел ширины не на масштабе 1")
                }
            }
        }
    }

    /// A wide, short sprite is capped by width, not by height — this is exactly the
    /// LuizMelo case, where the height rule alone would have asked for 135pt of width.
    func testWideSpriteIsCappedByWidth() {
        // 27x14 at the height rule alone would be floor(64/14) = 4... and 27*5 = 135,
        // so the width cap is what rejects 5.
        XCTAssertEqual(64 / 14, 4)
        XCTAssertEqual(SpriteScale.factor(boundsWidth: 30, boundsHeight: 8), 4)  // 120/30 = 4 wins over 64/8 = 8
    }

    func testDegenerateBoundsNeverProduceZeroOrNegative() {
        XCTAssertEqual(SpriteScale.factor(boundsWidth: 1, boundsHeight: 1), 64)
        XCTAssertEqual(SpriteScale.factor(boundsWidth: 4096, boundsHeight: 4096), 1)
        XCTAssertEqual(SpriteScale.factor(boundsWidth: 0, boundsHeight: 0), 1)
        XCTAssertEqual(SpriteScale.factor(boundsWidth: -5, boundsHeight: -5), 1)
    }
}
