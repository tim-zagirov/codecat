import XCTest
@testable import CodeCatCore

final class HooksInstallerTests: XCTestCase {
    let cmd = "/Applications/CodeCat.app/Contents/MacOS/codecat-hook"

    func obj(_ data: Data) -> [String: Any] {
        (try! JSONSerialization.jsonObject(with: data)) as! [String: Any]
    }

    func testInstallIntoEmptySettingsAddsAllFourEvents() throws {
        let out = try HooksInstaller.install(into: nil, hookCommand: cmd)
        let hooks = obj(out)["hooks"] as! [String: Any]
        for event in HooksInstaller.events {
            XCTAssertNotNil(hooks[event], "нет события \(event)")
        }
        XCTAssertTrue(HooksInstaller.isInstalled(in: out, hookCommand: cmd))
    }

    func testInstallPreservesForeignHooksAndOtherSettings() throws {
        let existing = """
        {"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"/other/tool"}]}]}}
        """.data(using: .utf8)!
        let out = try HooksInstaller.install(into: existing, hookCommand: cmd)
        let root = obj(out)
        XCTAssertEqual(root["model"] as? String, "opus")
        let stop = (root["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]
        let commands = stop.flatMap { ($0["hooks"] as! [[String: Any]]).compactMap { $0["command"] as? String } }
        XCTAssertTrue(commands.contains("/other/tool"))
        XCTAssertTrue(commands.contains(cmd))
    }

    func testInstallIsIdempotent() throws {
        let once = try HooksInstaller.install(into: nil, hookCommand: cmd)
        let twice = try HooksInstaller.install(into: once, hookCommand: cmd)
        let stop = (obj(twice)["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]
        let ours = stop.flatMap { ($0["hooks"] as! [[String: Any]]).compactMap { $0["command"] as? String } }
            .filter { $0 == cmd }
        XCTAssertEqual(ours.count, 1)
    }

    func testRemoveDeletesOnlyOurCommandAndCleansEmpty() throws {
        let existing = """
        {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/other/tool"}]}]}}
        """.data(using: .utf8)!
        let installed = try HooksInstaller.install(into: existing, hookCommand: cmd)
        let out = try HooksInstaller.remove(from: installed, hookCommand: cmd)
        XCTAssertFalse(HooksInstaller.isInstalled(in: out, hookCommand: cmd))
        let root = obj(out)
        let hooks = root["hooks"] as! [String: Any]
        // чужой Stop-хук остался
        XCTAssertNotNil(hooks["Stop"])
        // события, где были только мы, вычищены полностью
        XCTAssertNil(hooks["SessionStart"])
    }

    func testIsInstalledFalseForNilOrPartial() throws {
        XCTAssertFalse(HooksInstaller.isInstalled(in: nil, hookCommand: cmd))
        let partial = """
        {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\(cmd)"}]}]}}
        """.data(using: .utf8)!
        XCTAssertFalse(HooksInstaller.isInstalled(in: partial, hookCommand: cmd))
    }

    func testInvalidJSONThrows() {
        XCTAssertThrowsError(try HooksInstaller.install(
            into: "broken{".data(using: .utf8)!, hookCommand: cmd))
    }

    // MARK: - Additional coverage beyond the brief's sample

    func testRemovePreservesForeignKeysInSharedHookGroup() throws {
        // A hook group can carry extra keys (e.g. "matcher") alongside "hooks".
        // Removing our command from a group that still has entries left must not
        // silently drop those other keys.
        let existing = """
        {"hooks":{"Stop":[{"matcher":"*","hooks":[
            {"type":"command","command":"/other/tool"},
            {"type":"command","command":"\(cmd)"}
        ]}]}}
        """.data(using: .utf8)!
        let out = try HooksInstaller.remove(from: existing, hookCommand: cmd)
        let root = obj(out)
        let stop = (root["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]
        XCTAssertEqual(stop.count, 1)
        XCTAssertEqual(stop[0]["matcher"] as? String, "*")
        let inner = stop[0]["hooks"] as! [[String: Any]]
        XCTAssertEqual(inner.count, 1)
        XCTAssertEqual(inner[0]["command"] as? String, "/other/tool")
    }

    func testRemoveFromNilProducesEmptyValidJSON() throws {
        let out = try HooksInstaller.remove(from: nil, hookCommand: cmd)
        let root = obj(out)
        XCTAssertNil(root["hooks"])
    }

    func testRemoveLeavesUnrelatedEventsAndTopLevelKeysUntouched() throws {
        let existing = """
        {"otherSetting":true,"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/foreign/only"}]}],"Stop":[{"hooks":[{"type":"command","command":"\(cmd)"}]}]}}
        """.data(using: .utf8)!
        let out = try HooksInstaller.remove(from: existing, hookCommand: cmd)
        let root = obj(out)
        XCTAssertEqual(root["otherSetting"] as? Bool, true)
        let hooks = root["hooks"] as! [String: Any]
        XCTAssertNotNil(hooks["SessionStart"])
        XCTAssertNil(hooks["Stop"])
    }

    func testInvalidJSONThrowsForRemove() {
        XCTAssertThrowsError(try HooksInstaller.remove(
            from: "broken{".data(using: .utf8)!, hookCommand: cmd))
    }

    func testEventsListIsExactlyTheSpecifiedFour() {
        XCTAssertEqual(HooksInstaller.events, ["SessionStart", "Stop", "Notification", "SessionEnd"])
    }

    // MARK: - Malformed foreign content must survive install (review finding)

    /// Reproduces the data-loss bug: a `Stop` array containing a non-dictionary
    /// element used to fail the `as? [[String: Any]]` cast as a whole, so `?? []`
    /// replaced the entire array with just CodeCat's group, silently destroying
    /// the foreign string entry.
    func testInstallIntoArrayWithNonDictionaryElementPreservesIt() throws {
        let existing = """
        {"hooks":{"Stop":["not-a-dict-entry"]}}
        """.data(using: .utf8)!
        let out = try HooksInstaller.install(into: existing, hookCommand: cmd)
        let stop = (obj(out)["hooks"] as! [String: Any])["Stop"] as! [Any]
        let strings = stop.compactMap { $0 as? String }
        XCTAssertTrue(strings.contains("not-a-dict-entry"),
                       "the original non-dictionary element must survive install")
        let dicts = stop.compactMap { $0 as? [String: Any] }
        let commands = dicts.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
        XCTAssertTrue(commands.contains(cmd), "CodeCat's group must still be appended")
    }

    func testInstallIntoMixedArrayPreservesForeignGroupAndNonDictionaryElement() throws {
        let existing = """
        {"hooks":{"Stop":[
            {"matcher":"*","hooks":[{"type":"command","command":"/other/tool"}]},
            "not-a-dict-entry"
        ]}}
        """.data(using: .utf8)!
        let out = try HooksInstaller.install(into: existing, hookCommand: cmd)
        let stop = (obj(out)["hooks"] as! [String: Any])["Stop"] as! [Any]
        XCTAssertTrue(stop.contains { ($0 as? String) == "not-a-dict-entry" },
                      "the non-dictionary element must survive install")
        let dicts = stop.compactMap { $0 as? [String: Any] }
        let commands = dicts.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
        XCTAssertTrue(commands.contains("/other/tool"), "the well-formed foreign group must survive install")
        XCTAssertTrue(commands.contains(cmd), "CodeCat's group must be appended")
    }

    func testInstallIntoNonArrayEventValueThrowsAndDoesNotLoseData() throws {
        let existing = """
        {"hooks":{"Stop":"totally-unexpected"}}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try HooksInstaller.install(into: existing, hookCommand: cmd)) { error in
            guard case HooksInstallerError.unexpectedHooksShape(let event) = error else {
                return XCTFail("expected unexpectedHooksShape, got \(error)")
            }
            XCTAssertEqual(event, "Stop")
        }
    }

    func testInstallIntoMixedArrayIsIdempotent() throws {
        let existing = """
        {"hooks":{"Stop":["not-a-dict-entry"]}}
        """.data(using: .utf8)!
        let once = try HooksInstaller.install(into: existing, hookCommand: cmd)
        let twice = try HooksInstaller.install(into: once, hookCommand: cmd)
        let stop = (obj(twice)["hooks"] as! [String: Any])["Stop"] as! [Any]
        XCTAssertEqual(stop.filter { ($0 as? String) == "not-a-dict-entry" }.count, 1,
                       "the non-dictionary element must not be duplicated")
        let dicts = stop.compactMap { $0 as? [String: Any] }
        let commands = dicts.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
        XCTAssertEqual(commands.filter { $0 == cmd }.count, 1,
                       "CodeCat's group must not be duplicated on a second install")
    }

    // MARK: - Root-level "hooks" shape must not be silently destroyed (review finding 1)

    /// Reproduces the one-level-up version of the data-loss bug: a root `hooks`
    /// value that is a string (written by some foreign tool) used to fail the
    /// `as? [String: Any]` cast and get replaced via `?? [:]`, so the unconditional
    /// `root["hooks"] = hooks` at the end silently destroyed the foreign string.
    func testInstallIntoRootHooksStringThrowsAndDoesNotLoseData() throws {
        let existing = """
        {"hooks":"some-important-string-value-set-by-another-tool"}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try HooksInstaller.install(into: existing, hookCommand: cmd))
    }

    func testInstallIntoRootHooksArrayThrows() throws {
        let existing = """
        {"hooks":[1,2,3]}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try HooksInstaller.install(into: existing, hookCommand: cmd))
    }

    func testInstallWithNoHooksKeyAtAllStillSucceedsAndPreservesOtherKeys() throws {
        let existing = """
        {"model":"opus"}
        """.data(using: .utf8)!
        let out = try HooksInstaller.install(into: existing, hookCommand: cmd)
        let root = obj(out)
        XCTAssertEqual(root["model"] as? String, "opus")
        let hooks = root["hooks"] as! [String: Any]
        for event in HooksInstaller.events {
            XCTAssertNotNil(hooks[event], "missing event \(event)")
        }
        XCTAssertTrue(HooksInstaller.isInstalled(in: out, hookCommand: cmd))
    }

    // MARK: - remove must be symmetric with install on mixed arrays (review finding 2)

    func testRemoveFromMixedArrayPreservesForeignGroupAndNonDictionaryElement() throws {
        let existing = """
        {"hooks":{"Stop":[
            {"matcher":"*","hooks":[{"type":"command","command":"/other/tool"}]},
            "not-a-dict-entry",
            {"hooks":[{"type":"command","command":"\(cmd)"}]}
        ]}}
        """.data(using: .utf8)!
        let out = try HooksInstaller.remove(from: existing, hookCommand: cmd)
        let root = obj(out)
        let hooks = root["hooks"] as! [String: Any]
        let stop = hooks["Stop"] as! [Any]
        // our group is gone
        let dicts = stop.compactMap { $0 as? [String: Any] }
        let commands = dicts.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
        XCTAssertFalse(commands.contains(cmd), "our command must be removed")
        XCTAssertTrue(commands.contains("/other/tool"), "the foreign group must survive")
        XCTAssertTrue(stop.contains { ($0 as? String) == "not-a-dict-entry" },
                      "the non-dictionary element must survive")
    }

    func testRemoveFromArrayWithOnlyNonDictionaryElementAndOurGroupSurvivesEvent() throws {
        let existing = """
        {"hooks":{"Stop":[
            "not-a-dict-entry",
            {"hooks":[{"type":"command","command":"\(cmd)"}]}
        ]}}
        """.data(using: .utf8)!
        let out = try HooksInstaller.remove(from: existing, hookCommand: cmd)
        let root = obj(out)
        let hooks = root["hooks"] as! [String: Any]
        XCTAssertNotNil(hooks["Stop"], "event must survive because the non-dictionary element is still present")
        let stop = hooks["Stop"] as! [Any]
        XCTAssertTrue(stop.contains { ($0 as? String) == "not-a-dict-entry" })
        let dicts = stop.compactMap { $0 as? [String: Any] }
        let commands = dicts.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
        XCTAssertFalse(commands.contains(cmd), "our command must be removed")
    }
}
