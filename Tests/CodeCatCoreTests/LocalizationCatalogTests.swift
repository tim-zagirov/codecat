import XCTest
@testable import CodeCatCore

/// Guards the one failure mode a string catalog has that nothing else catches: it
/// never crashes. A key used in code but missing from the catalog silently falls
/// back to the English written at the call site, and a key left in the catalog
/// after its call site is gone is dead weight nobody notices.
///
/// CodeCat ships one language. The catalog still earns its place: it is what makes
/// every user-visible string reachable from one file, so the wording can be read
/// and revised as a whole rather than hunted through view bodies — and adding a
/// second language later is then a translation job, not a refactor.
///
/// Everything is checked against the repository, not the test bundle: `en.lproj`
/// is a resource of the *app* bundle, which the Makefile assembles, so there is
/// nothing for a test host to load. `#filePath` walks up to the repository root
/// the same way `SkinAssetsTests` does.
final class LocalizationCatalogTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // .../Tests/CodeCatCoreTests
        .deletingLastPathComponent()   // .../Tests
        .deletingLastPathComponent()   // repository root

    private func catalog() throws -> [String: String] {
        let url = Self.repoRoot.appendingPathComponent("Resources/en.lproj/Localizable.strings")
        let data = try Data(contentsOf: url)
        let parsed = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try XCTUnwrap(parsed as? [String: String], "en.lproj is not a strings dictionary")
    }

    /// Both directions. A key used in code but absent from the catalog means the
    /// wording lives at the call site alone, out of reach of anyone revising the
    /// copy; a key in the catalog with no call site is a string nobody will ever
    /// see, kept alive by nothing.
    func testTheCatalogAndTheCallSitesAgreeOnWhichKeysExist() throws {
        let catalog = try catalog()
        let used = try keysUsedInSources()
        XCTAssertFalse(catalog.isEmpty)
        XCTAssertFalse(used.isEmpty, "found no L10n call sites — did the helper get renamed?")
        XCTAssertEqual(used.subtracting(catalog.keys), [], "used in code, missing from en.lproj")
        XCTAssertEqual(Set(catalog.keys).subtracting(used), [], "in en.lproj, unused in code")
    }

    /// The catalog is loaded by `String(format:)` at runtime, so a stray `%` that
    /// is not a real placeholder formats garbage rather than failing to build.
    /// Every specifier has to be one the call sites actually pass.
    func testEveryFormatSpecifierIsOneTheCodeCanSupply() throws {
        let allowed = try NSRegularExpression(pattern: "%(?:(?:\\d+\\$)?[@d]|%)")
        let anyPercent = try NSRegularExpression(pattern: "%")
        for (key, text) in try catalog() {
            let range = NSRange(text.startIndex..., in: text)
            let valid = allowed.numberOfMatches(in: text, range: range)
            let total = anyPercent.numberOfMatches(in: text, range: range)
            XCTAssertEqual(valid, total, "\(key): contains a % that is not a supported placeholder")
        }
    }

    private func keysUsedInSources() throws -> Set<String> {
        let sources = Self.repoRoot.appendingPathComponent("Sources")
        let pattern = try NSRegularExpression(pattern: "L10n\\.[tf]\\(\"([^\"]+)\"")
        var keys: Set<String> = []
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: range) {
                keys.insert(String(text[Range(match.range(at: 1), in: text)!]))
            }
        }
        return keys
    }
}
