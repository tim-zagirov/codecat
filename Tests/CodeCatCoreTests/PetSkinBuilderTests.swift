import XCTest
@testable import CodeCatCore

/// The Codex sheet is a fixed 8×9 grid; CodeCat plays five of its nine rows. The
/// frame numbers below are the whole contract: row * 8 + column.
final class PetSkinBuilderTests: XCTestCase {

    private let manifest = PetManifest(id: "dewey", displayName: "Dewey",
                                       description: "A duck.", spritesheetPath: "spritesheet.webp")
    private let folder = URL(fileURLWithPath: "/tmp/pets/dewey", isDirectory: true)

    private func build(width: Int = 1536, height: Int = 1872) -> MascotSkin? {
        PetSkinBuilder.skin(manifest: manifest, directory: folder, sheetWidth: width, sheetHeight: height)
    }

    private func indices(_ skin: MascotSkin, _ key: AggregateStatusKey, phase: Int = 0) -> [Int] {
        skin.animations[key]!.phases[phase].frames.map(\.index)
    }

    func testCanonicalSheetGivesTheCodexCell() throws {
        let skin = try XCTUnwrap(build())
        XCTAssertEqual(skin.frameWidth, 192)
        XCTAssertEqual(skin.frameHeight, 208)
    }

    func testIdentityComesFromTheManifest() throws {
        let skin = try XCTUnwrap(build())
        XCTAssertEqual(skin.id, "pet:dewey")
        XCTAssertEqual(skin.name, "Dewey")
        XCTAssertEqual(skin.author, "Dewey")
        XCTAssertEqual(skin.note, "A duck.")
        XCTAssertEqual(skin.location, .external(folder))
        XCTAssertEqual(skin.sourceURL, folder.path)
        XCTAssertFalse(skin.bundled)
        XCTAssertEqual(skin.license, .authorTerms(summary: PetSkinBuilder.importedTerms))
        XCTAssertEqual(skin.declaredSheets, ["spritesheet.webp"])
    }

    /// Each row's last frame is listed twice: upstream holds it about twice as long.
    func testSleepingIsTheIdleRow() throws {
        let skin = try XCTUnwrap(build())
        XCTAssertEqual(indices(skin, .sleeping), [0, 1, 2, 3, 4, 5, 5])
        XCTAssertEqual(skin.animations[.sleeping]?.framesPerSecond, 5)
    }

    func testWorkingIsTheRunningRow() throws {
        let skin = try XCTUnwrap(build())
        XCTAssertEqual(indices(skin, .working), [56, 57, 58, 59, 60, 61, 61])
        XCTAssertEqual(skin.animations[.working]?.framesPerSecond, 8)
    }

    func testWaitingIsTheWaitingRow() throws {
        let skin = try XCTUnwrap(build())
        XCTAssertEqual(indices(skin, .waiting), [48, 49, 50, 51, 52, 53, 53])
        XCTAssertEqual(skin.animations[.waiting]?.framesPerSecond, 6.5)
    }

    func testProblemIsTheFailedRow() throws {
        let skin = try XCTUnwrap(build())
        XCTAssertEqual(indices(skin, .problem), [40, 41, 42, 43, 44, 45, 46, 47, 47])
        XCTAssertEqual(skin.animations[.problem]?.framesPerSecond, 7)
    }

    /// Done: jump twice, then settle into the review loop.
    func testDoneJumpsTwiceThenReviewsForever() throws {
        let skin = try XCTUnwrap(build())
        let done = try XCTUnwrap(skin.animations[.done])
        XCTAssertEqual(done.phases.count, 2)
        XCTAssertEqual(indices(skin, .done, phase: 0), [32, 33, 34, 35, 36, 36])
        XCTAssertEqual(done.phases[0].repeats, 2)
        XCTAssertEqual(done.phases[0].framesPerSecond, 7)
        XCTAssertEqual(indices(skin, .done, phase: 1), [64, 65, 66, 67, 68, 69, 69])
        XCTAssertNil(done.phases[1].repeats)
        XCTAssertEqual(done.phases[1].framesPerSecond, 6.5)
    }

    func testEveryStateIsCoveredAndWithinTheRegistryFPSRange() throws {
        let skin = try XCTUnwrap(build())
        for key in AggregateStatusKey.allCases {
            let animation = try XCTUnwrap(skin.animations[key], "\(key)")
            for phase in animation.phases {
                XCTAssertFalse(phase.frames.isEmpty)
                XCTAssertGreaterThanOrEqual(phase.framesPerSecond, 0.6)
                XCTAssertLessThanOrEqual(phase.framesPerSecond, 8)
            }
        }
    }

    /// A sheet at another resolution is fine as long as the grid divides.
    func testAnyMultipleOfTheGridIsAccepted() throws {
        let skin = try XCTUnwrap(build(width: 384, height: 468))
        XCTAssertEqual(skin.frameWidth, 48)
        XCTAssertEqual(skin.frameHeight, 52)
    }

    func testSheetsThatDoNotDivideIntoTheGridAreRejected() {
        XCTAssertNil(build(width: 1000, height: 1872))
        XCTAssertNil(build(width: 1536, height: 1000))
        XCTAssertNil(build(width: 0, height: 0))
        XCTAssertNil(build(width: -8, height: -9))
    }
}
