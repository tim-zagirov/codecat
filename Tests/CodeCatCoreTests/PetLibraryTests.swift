import XCTest
@testable import CodeCatCore

final class PetLibraryTests: XCTestCase {

    private var base: URL!
    private var ownRoot: URL { base.appendingPathComponent("own", isDirectory: true) }
    private var codexRoot: URL { base.appendingPathComponent("codex", isDirectory: true) }

    /// Every sheet "decodes" to the canonical size unless the test says otherwise.
    private var sizes: [String: (width: Int, height: Int)] = [:]
    private func sheetSize(_ url: URL) -> (width: Int, height: Int)? {
        sizes[url.lastPathComponent] ?? (1536, 1872)
    }

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("codecat-pets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: ownRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func pet(in root: URL, folder: String, manifest: String?, sheet: String? = "spritesheet.webp") throws {
        let dir = root.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let manifest {
            try manifest.write(to: dir.appendingPathComponent("pet.json"), atomically: true, encoding: .utf8)
        }
        if let sheet {
            try Data([0]).write(to: dir.appendingPathComponent(sheet))
        }
    }

    private func discover() -> PetLibrary.Result {
        PetLibrary.discover(roots: [ownRoot, codexRoot], sheetSize: sheetSize)
    }

    func testFindsPetsInEveryRootSortedByName() throws {
        try pet(in: codexRoot, folder: "zed", manifest: #"{"id":"zed","displayName":"Zed"}"#)
        try pet(in: ownRoot, folder: "amber", manifest: #"{"id":"amber","displayName":"Amber"}"#)
        let result = discover()
        XCTAssertEqual(result.skins.map(\.id), ["pet:amber", "pet:zed"])
        XCTAssertEqual(result.skins.map(\.location),
                       [.external(ownRoot.appendingPathComponent("amber", isDirectory: true)),
                        .external(codexRoot.appendingPathComponent("zed", isDirectory: true))])
        XCTAssertTrue(result.skipped.isEmpty)
    }

    /// A folder without a manifest is not a pet — no report, it is simply not one.
    func testFoldersWithoutAManifestAreIgnoredSilently() throws {
        try pet(in: codexRoot, folder: "notes", manifest: nil, sheet: nil)
        let result = discover()
        XCTAssertTrue(result.skins.isEmpty)
        XCTAssertTrue(result.skipped.isEmpty)
    }

    func testBrokenManifestIsSkippedAndReported() throws {
        try pet(in: codexRoot, folder: "bad", manifest: "{nope")
        let result = discover()
        XCTAssertTrue(result.skins.isEmpty)
        XCTAssertEqual(result.skipped.map(\.folder.lastPathComponent), ["bad"])
        XCTAssertTrue(result.skipped[0].reason.contains("pet.json"))
    }

    func testMissingSheetIsSkippedAndReported() throws {
        try pet(in: codexRoot, folder: "ghost", manifest: #"{"id":"ghost"}"#, sheet: nil)
        let result = discover()
        XCTAssertTrue(result.skins.isEmpty)
        XCTAssertTrue(result.skipped[0].reason.contains("spritesheet.webp"))
    }

    func testUndecodableSheetIsSkippedAndReported() throws {
        try pet(in: codexRoot, folder: "blob", manifest: #"{"id":"blob","spritesheetPath":"weird.bin"}"#, sheet: "weird.bin")
        let result = PetLibrary.discover(roots: [codexRoot]) { url in
            url.lastPathComponent == "weird.bin" ? nil : (1536, 1872)
        }
        XCTAssertTrue(result.skins.isEmpty)
        XCTAssertTrue(result.skipped[0].reason.contains("weird.bin"))
    }

    func testWrongGridIsSkippedWithTheSizeInTheReason() throws {
        try pet(in: codexRoot, folder: "odd", manifest: #"{"id":"odd"}"#)
        // 1000 is a multiple of the 8-column grid (unlike a genuinely wrong
        // sheet), so it would build a valid skin instead of being rejected;
        // 1001 is not a multiple of 8 and actually exercises the wrong-grid path.
        let result = PetLibrary.discover(roots: [codexRoot]) { _ in (1001, 1872) }
        XCTAssertTrue(result.skins.isEmpty)
        XCTAssertTrue(result.skipped[0].reason.contains("1001x1872"))
    }

    /// Roots are searched in order; CodeCat's own folder comes first, so a pet
    /// there overrides a same-named one in the Codex folder.
    func testFirstRootWinsOnADuplicateID() throws {
        try pet(in: ownRoot, folder: "dewey", manifest: #"{"id":"dewey","displayName":"Mine"}"#)
        try pet(in: codexRoot, folder: "dewey", manifest: #"{"id":"dewey","displayName":"Theirs"}"#)
        let result = discover()
        XCTAssertEqual(result.skins.map(\.name), ["Mine"])
        XCTAssertEqual(result.skipped.map(\.folder), [codexRoot.appendingPathComponent("dewey", isDirectory: true)])
        XCTAssertTrue(result.skipped[0].reason.contains("dewey"))
    }

    func testMissingRootsAreFine() {
        let result = PetLibrary.discover(roots: [base.appendingPathComponent("nowhere")]) { _ in (1536, 1872) }
        XCTAssertTrue(result.skins.isEmpty)
        XCTAssertTrue(result.skipped.isEmpty)
    }

    /// Swift's `sort` is not stable, so two pets sharing a display name need an
    /// explicit tiebreak or their order could flip between rescans.
    func testPetsWithTheSameNameKeepAStableOrder() throws {
        try pet(in: ownRoot, folder: "twin-b", manifest: #"{"id":"twin-b","displayName":"Twin"}"#)
        try pet(in: codexRoot, folder: "twin-a", manifest: #"{"id":"twin-a","displayName":"Twin"}"#)
        let result = discover()
        XCTAssertEqual(result.skins.map(\.id), ["pet:twin-a", "pet:twin-b"])
    }

    func testDefaultRootsAreOwnFolderThenCodexHome() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        let plain = PetLibrary.defaultRoots(environment: [:], home: home)
        XCTAssertEqual(plain, [CodeCatPaths.petsRoot,
                               URL(fileURLWithPath: "/Users/someone/.codex/pets", isDirectory: true)])
        let custom = PetLibrary.defaultRoots(environment: ["CODEX_HOME": "/opt/codex"], home: home)
        XCTAssertEqual(custom.last, URL(fileURLWithPath: "/opt/codex/pets", isDirectory: true))
    }
}
