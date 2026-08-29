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
}
