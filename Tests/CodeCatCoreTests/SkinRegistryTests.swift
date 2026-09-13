import XCTest
@testable import CodeCatCore

final class SkinRegistryTests: XCTestCase {

    private let pet = PetSkinBuilder.skin(
        manifest: PetManifest(id: "dewey", displayName: "Dewey", description: nil,
                              spritesheetPath: "spritesheet.webp"),
        directory: URL(fileURLWithPath: "/tmp/pets/dewey", isDirectory: true),
        sheetWidth: 1536, sheetHeight: 1872)!

    func testInstalledIsBuiltInsThenImported() {
        let registry = SkinRegistry(imported: [pet])
        XCTAssertEqual(registry.installed.map(\.id), MascotSkins.all.map(\.id) + ["pet:dewey"])
    }

    func testResolvesBuiltInAndImportedIDs() {
        let registry = SkinRegistry(imported: [pet])
        XCTAssertEqual(registry.skin(withID: "mxmaze-kitty").id, "mxmaze-kitty")
        XCTAssertEqual(registry.skin(withID: "pet:dewey"), pet)
    }

    /// A pet that was deleted since the id was stored must not strand the user.
    func testUnknownIDFallsBackToTheDefault() {
        XCTAssertEqual(SkinRegistry().skin(withID: "pet:dewey"), MascotSkins.default)
        XCTAssertEqual(SkinRegistry().skin(withID: "drawn"), MascotSkins.default)
    }

    func testImportedIsRecognisedByThePrefix() {
        XCTAssertTrue(SkinRegistry.isImported(pet))
        XCTAssertFalse(SkinRegistry.isImported(MascotSkins.default))
    }
}
