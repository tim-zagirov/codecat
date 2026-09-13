import XCTest
@testable import CodeCatCore

/// `pet.json` as the hatch-pet skill writes it: four strings. Everything here is
/// about not falling over when a hand-edited file is short a key.
final class PetManifestTests: XCTestCase {

    private func parse(_ json: String, folder: String = "folder") -> PetManifest? {
        PetManifest.parse(Data(json.utf8), folderName: folder)
    }

    func testFullManifest() {
        let m = parse(#"{"id":"dewey","displayName":"Dewey","description":"A duck.","spritesheetPath":"spritesheet.webp"}"#)
        XCTAssertEqual(m, PetManifest(id: "dewey", displayName: "Dewey",
                                      description: "A duck.", spritesheetPath: "spritesheet.webp"))
    }

    func testIDFallsBackToTheFolderName() {
        XCTAssertEqual(parse(#"{"displayName":"Dewey"}"#, folder: "my-duck")?.id, "my-duck")
    }

    func testDisplayNameFallsBackToTheID() {
        XCTAssertEqual(parse(#"{"id":"dewey"}"#)?.displayName, "dewey")
    }

    func testSheetPathDefaultsToTheCanonicalName() {
        XCTAssertEqual(parse(#"{"id":"dewey"}"#)?.spritesheetPath, "spritesheet.webp")
        XCTAssertEqual(parse(#"{"id":"dewey","spritesheetPath":"sheet.png"}"#)?.spritesheetPath, "sheet.png")
    }

    func testDescriptionIsOptional() {
        XCTAssertNil(parse(#"{"id":"dewey"}"#)?.description)
    }

    /// An empty string is a missing value, not a name.
    func testEmptyStringsCountAsMissing() {
        let m = parse(#"{"id":"","displayName":"","description":"","spritesheetPath":""}"#, folder: "f")
        XCTAssertEqual(m?.id, "f")
        XCTAssertEqual(m?.displayName, "f")
        XCTAssertNil(m?.description)
        XCTAssertEqual(m?.spritesheetPath, "spritesheet.webp")
    }

    func testUnknownKeysAreIgnored() {
        XCTAssertEqual(parse(#"{"id":"dewey","tags":["duck"],"version":2}"#)?.id, "dewey")
    }

    func testAnythingButAnObjectIsNil() {
        XCTAssertNil(parse(#"["dewey"]"#))
        XCTAssertNil(parse("{not json"))
        XCTAssertNil(parse(""))
    }
}
