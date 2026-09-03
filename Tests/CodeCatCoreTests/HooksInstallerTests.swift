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
            XCTAssertNotNil(hooks[event], "missing event \(event)")
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
        // someone else's Stop hook survived
        XCTAssertNotNil(hooks["Stop"])
        // events that held only ours are cleared out entirely
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

    /// The event list is pinned in full: each one is responsible for a specific state
    /// transition, and an event that silently dropped out means a stuck cat.
    /// `UserPromptSubmit` is the moment work begins (see the doc comment on `events`).
    func testEventsListIsExactlyTheSubscribedFive() {
        XCTAssertEqual(HooksInstaller.events,
                       ["SessionStart", "UserPromptSubmit", "Stop", "Notification", "SessionEnd"])
    }

    /// An installation made by an older version (without `UserPromptSubmit`) must read
    /// as incomplete: otherwise the app would decide everything was in place and never
    /// offer to add the missing event.
    func testAnOlderPartialInstallDoesNotCountAsInstalled() throws {
        let older = try JSONSerialization.data(withJSONObject: ["hooks": [
            "SessionStart": [["hooks": [["type": "command", "command": cmd]]]],
            "Stop": [["hooks": [["type": "command", "command": cmd]]]],
            "Notification": [["hooks": [["type": "command", "command": cmd]]]],
            "SessionEnd": [["hooks": [["type": "command", "command": cmd]]]],
        ]])
        XCTAssertFalse(HooksInstaller.isInstalled(in: older, hookCommand: cmd))
        // And after installing — present, with no old entries duplicated.
        let updated = try HooksInstaller.install(into: older, hookCommand: cmd)
        XCTAssertTrue(HooksInstaller.isInstalled(in: updated, hookCommand: cmd))
        let root = (try JSONSerialization.jsonObject(with: updated)) as? [String: Any]
        let hooks = root?["hooks"] as? [String: Any]
        XCTAssertEqual((hooks?["Stop"] as? [Any])?.count, 1)
        XCTAssertEqual((hooks?["UserPromptSubmit"] as? [Any])?.count, 1)
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

    // MARK: - Remaining defect instances (task-6): per-group inner "hooks" cast
    // and isInstalled's per-event cast must not use a destructive `?? []`/`?? [:]`
    // fallback either.

    /// Instance A repro: a group's inner "hooks" array mixes a foreign command
    /// entry with a non-dictionary element. Removing a command that appears
    /// nowhere in the document must be a complete no-op — previously the
    /// `as? [[String: Any]] ?? []` cast on the mixed inner array failed as a
    /// whole, `inner` became `[]`, and the group (matcher, foreign command,
    /// and all) was wiped out even though CodeCat's command was never there.
    func testRemoveAbsentCommandFromMixedInnerArrayIsANoOp() throws {
        let existing = """
        {"hooks":{"Stop":[{"matcher":"*","hooks":[
            {"type":"command","command":"/other/tool"},
            "unexpected-string-entry"
        ]}]}}
        """.data(using: .utf8)!
        let out = try HooksInstaller.remove(from: existing, hookCommand: cmd)
        let root = obj(out)
        let hooks = root["hooks"] as! [String: Any]
        XCTAssertNotNil(hooks["Stop"], "the Stop event must survive untouched")
        let stop = hooks["Stop"] as! [Any]
        XCTAssertEqual(stop.count, 1)
        let group = stop[0] as! [String: Any]
        XCTAssertEqual(group["matcher"] as? String, "*")
        let inner = group["hooks"] as! [Any]
        XCTAssertEqual(inner.count, 2)
        let innerDicts = inner.compactMap { $0 as? [String: Any] }
        XCTAssertTrue(innerDicts.contains { ($0["command"] as? String) == "/other/tool" },
                      "the foreign command entry must survive")
        XCTAssertTrue(inner.contains { ($0 as? String) == "unexpected-string-entry" },
                      "the non-dictionary inner element must survive")
    }

    /// Instance A, second half: removing CodeCat's command from a group whose
    /// inner array holds CodeCat's entry plus a non-dictionary element must
    /// delete only our entry, keeping the non-dictionary element and the group.
    func testRemoveOurCommandFromMixedInnerArrayPreservesNonDictionaryElement() throws {
        let existing = """
        {"hooks":{"Stop":[{"hooks":[
            {"type":"command","command":"\(cmd)"},
            "unexpected-string-entry"
        ]}]}}
        """.data(using: .utf8)!
        let out = try HooksInstaller.remove(from: existing, hookCommand: cmd)
        let root = obj(out)
        let hooks = root["hooks"] as! [String: Any]
        XCTAssertNotNil(hooks["Stop"], "the group must survive since the non-dictionary element remains")
        let stop = hooks["Stop"] as! [Any]
        XCTAssertEqual(stop.count, 1)
        let group = stop[0] as! [String: Any]
        let inner = group["hooks"] as! [Any]
        XCTAssertEqual(inner.count, 1)
        XCTAssertTrue(inner.contains { ($0 as? String) == "unexpected-string-entry" },
                      "the non-dictionary inner element must survive")
        let innerDicts = inner.compactMap { $0 as? [String: Any] }
        XCTAssertFalse(innerDicts.contains { ($0["command"] as? String) == cmd },
                       "our command entry must be gone")
    }

    /// A group can be a dictionary with no "hooks" key at all (e.g. authored by
    /// hand, or by some other tool). It must survive removal untouched, while a
    /// separate group that does hold our command is still cleaned up.
    func testRemoveWithMatcherOnlyGroupAlongsideOurGroup() throws {
        let existing = """
        {"hooks":{"Stop":[
            {"matcher":"*"},
            {"hooks":[{"type":"command","command":"\(cmd)"}]}
        ]}}
        """.data(using: .utf8)!
        let out = try HooksInstaller.remove(from: existing, hookCommand: cmd)
        let root = obj(out)
        let hooks = root["hooks"] as! [String: Any]
        let stop = hooks["Stop"] as! [Any]
        XCTAssertEqual(stop.count, 1, "only the matcher-only group should remain")
        let group = stop[0] as! [String: Any]
        XCTAssertEqual(group["matcher"] as? String, "*")
        XCTAssertNil(group["hooks"])
    }

    /// Instance B repro: `install` deliberately preserves non-dictionary
    /// elements mixed into an event's array, so that shape is a legitimate
    /// output of `install`. `isInstalled` must recognize the command inside it
    /// rather than failing the whole-array cast and reporting `false`.
    func testIsInstalledTrueAfterInstallingIntoEventArrayWithForeignJunk() throws {
        let existing = """
        {"hooks":{"Stop":["foreign-junk"]}}
        """.data(using: .utf8)!
        let installed = try HooksInstaller.install(into: existing, hookCommand: cmd)
        XCTAssertTrue(HooksInstaller.isInstalled(in: installed, hookCommand: cmd),
                      "isInstalled must find our command even when the event array has foreign junk")
    }

    // MARK: - readSettings (Important 1)

    /// Pins Important 1: a missing settings file (first-ever install) must read as
    /// `.notFound`, which the caller then treats as an empty document — the correct,
    /// safe behavior for a first install.
    func testReadSettingsNotFoundWhenFileMissing() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = dir.appendingPathComponent("settings.json")
        XCTAssertEqual(HooksInstaller.readSettings(at: url), .notFound)
    }

    func testReadSettingsReturnsDataForReadableFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("settings.json")
        let payload = "{\"model\":\"opus\"}".data(using: .utf8)!
        try payload.write(to: url)
        XCTAssertEqual(HooksInstaller.readSettings(at: url), .data(payload))
    }

    /// Pins Important 1's core distinction: a file that *exists* but cannot be read as
    /// data (here: a directory sitting at the settings path, which `fileExists` reports
    /// as present but `Data(contentsOf:)` cannot read) must come back as `.unreadable`,
    /// never silently collapse into the same `nil`/empty-document treatment as
    /// `.notFound` — collapsing the two is exactly what let a transient read failure
    /// destroy a user's real settings file.
    func testReadSettingsUnreadableWhenPathExistsButCannotBeReadAsData() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // A directory at the settings path: `fileExists` is true, but `Data(contentsOf:)`
        // fails — the same shape of failure as unreadable permissions, without needing a
        // chmod that might behave differently across CI environments/users (e.g. root).
        let url = dir.appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        XCTAssertEqual(HooksInstaller.readSettings(at: url), .unreadable)
    }
}
