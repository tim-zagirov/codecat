import XCTest
@testable import CodeCatCore

final class SpriteScaleTests: XCTestCase {

    /// The three packs actually shipped, measured from their pixels. LuizMelo's six
    /// cats don't share one exact bounding box — most (including cat-1) measure
    /// 27x14, but cat-4 is 28x16 and cat-5 is 27x16 — though all six still land on
    /// the same integer scale below, which is the property this test actually
    /// covers. Elthen's is 18x12, mxmaze's fills its whole 16x16 tile.
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
        // The height rule alone would give floor(64/8) = 8, but the width cap rejects it.
        // The width rule gives 120/30 = 4, which wins.
        XCTAssertEqual(SpriteScale.factor(boundsWidth: 30, boundsHeight: 8), 4)  // 120/30 = 4 wins over 64/8 = 8
    }

    func testDegenerateBoundsNeverProduceZeroOrNegative() {
        XCTAssertEqual(SpriteScale.factor(boundsWidth: 1, boundsHeight: 1), 64)
        XCTAssertEqual(SpriteScale.factor(boundsWidth: 4096, boundsHeight: 4096), 1)
        XCTAssertEqual(SpriteScale.factor(boundsWidth: 0, boundsHeight: 0), 1)
        XCTAssertEqual(SpriteScale.factor(boundsWidth: -5, boundsHeight: -5), 1)
    }

    // MARK: - Островная нормировка (строка меню 32 pt)

    /// Все облики в строке меню обязаны получить один и тот же целочисленный
    /// множитель, иначе коты разъедутся по высоте вдвое, как это уже было на
    /// канве маскота. Рамки — те же, что в тесте выше: шесть котов LuizMelo не
    /// делят одну рамку (cat-4 — 28x16, cat-5 — 27x16).
    func testEverySkinLandsOnTimesTwoInTheMenuBar() {
        let bounds = [(27, 14), (28, 16), (27, 16), (18, 12), (16, 16)]
        for (w, h) in bounds {
            XCTAssertEqual(SpriteScale.factor(boundsWidth: w, boundsHeight: h,
                                              targetHeight: SpriteScale.islandTargetHeight,
                                              maxWidth: SpriteScale.islandMaxWidth),
                           2, "\(w)x\(h)")
        }
    }

    /// Прямая причина, по которой islandTargetHeight равен именно 32: на 30 pt
    /// mxmaze (16x16) падает до x1 и становится вдвое мельче остальных.
    func testALowerTargetWouldHalveTheSquareSkin() {
        XCTAssertEqual(SpriteScale.factor(boundsWidth: 16, boundsHeight: 16,
                                          targetHeight: 30, maxWidth: 60), 1)
    }

    /// Ни один облик не должен вылезти за отведённую ширину крыла.
    func testIslandWidthsStayWithinTheCap() {
        let bounds = [(27, 14), (28, 16), (27, 16), (18, 12), (16, 16)]
        for (w, h) in bounds {
            let s = SpriteScale.factor(boundsWidth: w, boundsHeight: h,
                                       targetHeight: SpriteScale.islandTargetHeight,
                                       maxWidth: SpriteScale.islandMaxWidth)
            XCTAssertLessThanOrEqual(w * s, SpriteScale.islandMaxWidth, "\(w)x\(h)")
            XCTAssertLessThanOrEqual(h * s, SpriteScale.islandTargetHeight, "\(w)x\(h)")
        }
    }

    /// Плавающий кот не имеет права поменяться ни на пиксель: вызов без новых
    /// параметров обязан давать ровно то же, что и раньше.
    func testDefaultArgumentsReproduceTheFloatingMascot() {
        XCTAssertEqual(SpriteScale.factor(boundsWidth: 27, boundsHeight: 14), 4)
        XCTAssertEqual(SpriteScale.factor(boundsWidth: 18, boundsHeight: 12), 5)
        XCTAssertEqual(SpriteScale.factor(boundsWidth: 16, boundsHeight: 16), 4)
        XCTAssertEqual(SpriteScale.factor(boundsWidth: 27, boundsHeight: 14,
                                          targetHeight: SpriteScale.targetHeight,
                                          maxWidth: SpriteScale.maxWidth), 4)
    }
}
