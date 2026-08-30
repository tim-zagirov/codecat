import XCTest
import CoreGraphics
@testable import CodeCatCore

final class MascotLayoutTests: XCTestCase {

    /// The panel window must be strictly larger than the drawing, otherwise the
    /// window's own edge clips whatever the animation swings outward (measured:
    /// the working tail reaches 55.2pt from center, so the drawing needs a
    /// canvas of at least 110.5pt).
    func testCanvasIsLargerThanTheDrawingItself() {
        XCTAssertGreaterThanOrEqual(MascotLayout.canvasSize, 111)
        XCTAssertGreaterThan(MascotLayout.canvasSize, MascotLayout.drawingSize)
    }

    func testMarginIsHalfTheGrowth() {
        XCTAssertEqual(MascotLayout.margin,
                       (MascotLayout.canvasSize - MascotLayout.drawingSize) / 2,
                       accuracy: 0.001)
    }

    // MARK: - Migrating a position saved by an earlier, smaller window

    /// The cat is drawn centred in its window, so growing the window around the
    /// same origin would visibly shove the cat up and to the right. Shifting the
    /// origin by half the growth keeps the drawing exactly where the user left it.
    func testMigratedOriginKeepsTheDrawingInPlace() {
        let saved = CGPoint(x: 1000, y: 200)
        let migrated = MascotLayout.migratedOrigin(saved, fromCanvas: 96, toCanvas: 128)
        XCTAssertEqual(migrated.x, 984, accuracy: 0.001)
        XCTAssertEqual(migrated.y, 184, accuracy: 0.001)
    }

    func testMigratedOriginIsIdentityWhenTheCanvasDidNotChange() {
        let saved = CGPoint(x: 12, y: 34)
        let migrated = MascotLayout.migratedOrigin(saved, fromCanvas: 128, toCanvas: 128)
        XCTAssertEqual(migrated, saved)
    }

    /// The centre of the drawing — not the window origin — is what the user sees,
    /// so migration must preserve it for any pair of sizes.
    func testMigrationPreservesTheDrawingCentreForAnySizes() {
        let saved = CGPoint(x: -300, y: 77)
        let migrated = MascotLayout.migratedOrigin(saved, fromCanvas: 96, toCanvas: 140)
        XCTAssertEqual(migrated.x + 70, saved.x + 48, accuracy: 0.001)
        XCTAssertEqual(migrated.y + 70, saved.y + 48, accuracy: 0.001)
    }

    // MARK: - Default placement

    /// The bottom-right corner placement is about where the *cat* sits, not where
    /// the invisible window edge sits: the transparent margin must not push the
    /// cat away from the corner it used to occupy.
    func testDefaultOriginInsetsTheDrawingNotTheWindow() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = MascotLayout.defaultOrigin(visibleFrame: visible, inset: 24)
        // The drawing box (drawingSize wide) should sit `inset` from the corner.
        let drawingMaxX = origin.x + MascotLayout.margin + MascotLayout.drawingSize
        let drawingMinY = origin.y + MascotLayout.margin
        XCTAssertEqual(drawingMaxX, 1440 - 24, accuracy: 0.001)
        XCTAssertEqual(drawingMinY, 24, accuracy: 0.001)
    }

    func testDefaultOriginRespectsAnOffsetScreen() {
        let visible = CGRect(x: -1920, y: 100, width: 1920, height: 1080)
        let origin = MascotLayout.defaultOrigin(visibleFrame: visible, inset: 24)
        XCTAssertEqual(origin.x + MascotLayout.margin + MascotLayout.drawingSize,
                       -24, accuracy: 0.001)
        XCTAssertEqual(origin.y + MascotLayout.margin, 124, accuracy: 0.001)
    }

    // MARK: - Guarding a saved position against disconnected displays

    func testSavedOriginIsAcceptedWhenItLandsOnAnAttachedScreen() {
        let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900)]
        XCTAssertTrue(MascotLayout.isOnScreen(origin: CGPoint(x: 1300, y: 40), screens: screens))
    }

    func testSavedOriginIsRejectedWhenItsDisplayIsGone() {
        let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900)]
        XCTAssertFalse(MascotLayout.isOnScreen(origin: CGPoint(x: 3000, y: 40), screens: screens))
    }

    /// A window only touching a screen by its transparent margin still counts as
    /// on-screen: the check is about "can the user find it", and the same rule
    /// applied before the window grew.
    func testSavedOriginTouchingTheScreenEdgeCounts() {
        let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900)]
        let origin = CGPoint(x: 1439, y: 40)
        XCTAssertTrue(MascotLayout.isOnScreen(origin: origin, screens: screens))
    }
}

// MARK: - Decoding a persisted position

extension MascotLayoutTests {

    /// Positions are stored together with the canvas they were saved for, so a
    /// later change of the canvas size migrates itself without another one-off
    /// defaults key.
    func testStoredOriginIsMigratedFromTheCanvasItWasSavedFor() {
        let origin = MascotLayout.storedOrigin(current: [1000, 200, 96], legacy: nil)
        XCTAssertEqual(origin?.x, 984)
        XCTAssertEqual(origin?.y, 184)
    }

    func testStoredOriginIsUsedAsIsWhenSavedForTheCurrentCanvas() {
        let origin = MascotLayout.storedOrigin(
            current: [1000, 200, Double(MascotLayout.canvasSize)], legacy: nil)
        XCTAssertEqual(origin?.x, 1000)
        XCTAssertEqual(origin?.y, 200)
    }

    /// A position written by the pre-fix build lives under the old key as a bare
    /// pair and always meant a 96pt window.
    func testLegacyPairIsMigratedFromTheOldWindowSize() {
        let origin = MascotLayout.storedOrigin(current: nil, legacy: [1000, 200])
        XCTAssertEqual(origin?.x, 1000 - (Double(MascotLayout.canvasSize) - 96) / 2)
        XCTAssertEqual(origin?.y, 200 - (Double(MascotLayout.canvasSize) - 96) / 2)
    }

    func testCurrentKeyWinsOverTheLegacyOne() {
        let origin = MascotLayout.storedOrigin(
            current: [10, 20, Double(MascotLayout.canvasSize)], legacy: [999, 999])
        XCTAssertEqual(origin?.x, 10)
        XCTAssertEqual(origin?.y, 20)
    }

    func testNothingStoredMeansNoOrigin() {
        XCTAssertNil(MascotLayout.storedOrigin(current: nil, legacy: nil))
    }

    func testMalformedStoredValuesAreIgnored() {
        XCTAssertNil(MascotLayout.storedOrigin(current: [1, 2], legacy: nil))
        XCTAssertNil(MascotLayout.storedOrigin(current: nil, legacy: [1]))
        XCTAssertNil(MascotLayout.storedOrigin(current: [], legacy: []))
    }

    /// A stored canvas of zero (or a negative one) is corrupt data, not a hint to
    /// shift the cat half a canvas across the screen.
    func testStoredOriginWithANonsenseCanvasIsIgnored() {
        XCTAssertNil(MascotLayout.storedOrigin(current: [1000, 200, 0], legacy: nil))
        XCTAssertNil(MascotLayout.storedOrigin(current: [1000, 200, -96], legacy: nil))
    }

    func testEncodingRoundTripsThroughStoredOrigin() {
        let stored = MascotLayout.storedValue(for: CGPoint(x: 321, y: 654))
        let origin = MascotLayout.storedOrigin(current: stored, legacy: nil)
        XCTAssertEqual(origin?.x, 321)
        XCTAssertEqual(origin?.y, 654)
    }
}
