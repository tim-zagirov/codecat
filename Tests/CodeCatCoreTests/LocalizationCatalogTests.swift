import XCTest
@testable import CodeCatCore

/// Guards the one failure mode a string catalog has that nothing else catches: it
/// never crashes. A key missing from `ru.lproj` shows English, a key missing from
/// the code is dead weight, and a `%d` that became `%@` in translation formats
/// garbage — all silently, in a language the author may not read.
///
/// Everything is checked against the repository, not the test bundle: the `.lproj`
/// directories are resources of the *app* bundle, which the Makefile assembles, so
/// there is nothing for a test host to load. `#filePath` walks up to the repo root
/// the same way `SkinAssetsTests` does.
final class LocalizationCatalogTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // .../Tests/CodeCatCoreTests
        .deletingLastPathComponent()   // .../Tests
        .deletingLastPathComponent()   // repo root

    private func catalog(_ language: String) throws -> [String: String] {
        let url = Self.repoRoot
            .appendingPathComponent("Resources/\(language).lproj/Localizable.strings")
        let data = try Data(contentsOf: url)
        let parsed = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil)
        return try XCTUnwrap(parsed as? [String: String], "\(language): not a strings dictionary")
    }

    /// Conversion specifiers in the order they appear, positional indices stripped:
    /// `"%1$@ … %2$d"` becomes `["@", "d"]`. Positional forms are what let a
    /// translation reorder arguments, so the *order* of the letters is not what
    /// matters — the multiset is.
    private func specifiers(in format: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: "%(?:(\\d+)\\$)?([@dfs])")
        let range = NSRange(format.startIndex..., in: format)
        return pattern.matches(in: format, range: range).map { match in
            String(format[Range(match.range(at: 2), in: format)!])
        }.sorted()
    }

    func testRussianTranslatesEveryEnglishKeyAndInventsNone() throws {
        let en = try catalog("en")
        let ru = try catalog("ru")
        XCTAssertFalse(en.isEmpty)
        XCTAssertEqual(Set(en.keys).subtracting(ru.keys), [], "untranslated keys")
        XCTAssertEqual(Set(ru.keys).subtracting(en.keys), [], "keys that exist only in Russian")
    }

    /// A translation whose placeholders do not match the English one is not a
    /// cosmetic problem: `String(format:)` reads whatever is on the stack for a
    /// `%@` the caller passed an `Int` for.
    func testEveryTranslationTakesTheSameArgumentsAsTheEnglishText() throws {
        let en = try catalog("en")
        let ru = try catalog("ru")
        for (key, english) in en {
            guard let russian = ru[key] else { continue }  // reported by the test above
            XCTAssertEqual(specifiers(in: english), specifiers(in: russian),
                           "\(key): placeholders differ between en and ru")
        }
    }

    /// Both directions. A key used in code but absent from the catalog silently
    /// falls back to the English written at the call site — so the Russian build
    /// loses one string and nothing says so. A key in the catalog that no longer
    /// exists in code is a translator's wasted work.
    func testTheCatalogAndTheCallSitesAgreeOnWhichKeysExist() throws {
        let en = try catalog("en")
        let used = try keysUsedInSources()
        XCTAssertFalse(used.isEmpty, "found no L10n call sites — did the helper get renamed?")
        XCTAssertEqual(used.subtracting(en.keys), [], "used in code, missing from en.lproj")
        XCTAssertEqual(Set(en.keys).subtracting(used), [], "in en.lproj, unused in code")
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
