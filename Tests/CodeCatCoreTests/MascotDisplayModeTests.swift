import XCTest
@testable import CodeCatCore

final class MascotDisplayModeTests: XCTestCase {

    /// The rawValue goes into UserDefaults, so these strings must never change — the
    /// user's chosen mode would silently reset.
    func testRawValuesAreStable() {
        XCTAssertEqual(MascotDisplayMode.floating.rawValue, "floating")
        XCTAssertEqual(MascotDisplayMode.island.rawValue, "island")
    }

    /// The default is what it has always been: the floating cat. Installing an updated
    /// app has no right to change the user's view by itself.
    func testDefaultIsTheFloatingMascot() {
        XCTAssertEqual(MascotDisplayMode.default, .floating)
    }

    /// Garbage and a missing value in the settings both land on the default mode rather
    /// than crashing.
    func testUnknownIdentifiersFallBackToTheDefault() {
        XCTAssertEqual(MascotDisplayMode.mode(withID: nil), .floating)
        XCTAssertEqual(MascotDisplayMode.mode(withID: ""), .floating)
        XCTAssertEqual(MascotDisplayMode.mode(withID: "notch"), .floating)
        XCTAssertEqual(MascotDisplayMode.mode(withID: "island"), .island)
    }

    func testEveryModeHasARussianTitle() {
        XCTAssertEqual(MascotDisplayMode.allCases.count, 2)
        for mode in MascotDisplayMode.allCases {
            XCTAssertFalse(mode.title.isEmpty, mode.rawValue)
        }
    }
}
