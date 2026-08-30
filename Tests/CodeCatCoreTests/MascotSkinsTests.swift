import XCTest
@testable import CodeCatCore

final class MascotSkinsTests: XCTestCase {

    /// The key is a *flat* projection of the aggregate status: the animation depends
    /// on the kind of state, never on how many sessions are in it. Covering
    /// `.working`/`.waiting` with several counts is what keeps a future
    /// "count-sensitive" mapping from sneaking in unnoticed.
    func testStatusKeyIgnoresSessionCount() {
        XCTAssertEqual(AggregateStatusKey(.sleeping), .sleeping)
        XCTAssertEqual(AggregateStatusKey(.done), .done)
        XCTAssertEqual(AggregateStatusKey(.problem), .problem)
        for n in [0, 1, 2, 17, 999] {
            XCTAssertEqual(AggregateStatusKey(.working(n)), .working)
            XCTAssertEqual(AggregateStatusKey(.waiting(n)), .waiting)
        }
    }

    func testOnlyCCBYRequiresAttribution() {
        XCTAssertTrue(SkinLicense.ccBy4(attributionTo: "кто-то").requiresAttribution)
        XCTAssertFalse(SkinLicense.cc0.requiresAttribution)
        XCTAssertFalse(SkinLicense.authorTerms(summary: "условия автора").requiresAttribution)
        XCTAssertFalse(SkinLicense.builtIn.requiresAttribution)
    }

    func testAnimationLookupReturnsNilForAMissingState() {
        let skin = MascotSkin(
            id: "test", name: "Тестовый", author: "никто", license: .builtIn,
            sourceURL: "https://example.com", directory: nil, frameSize: 16,
            animations: [.sleeping: SpriteAnimation(
                frames: [SpriteFrame(sheet: "a.png", index: 0)], framesPerSecond: 1)])
        XCTAssertEqual(skin.animation(for: .sleeping)?.frames.count, 1)
        XCTAssertNil(skin.animation(for: .working))
    }
}
