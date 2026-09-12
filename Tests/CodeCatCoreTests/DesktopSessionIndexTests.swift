import XCTest
@testable import CodeCatCore

/// The desktop Claude app keeps one JSON record per Claude Code session under
/// `claude-code-sessions/<org>/<user>/local_<id>.json`, and each record carries the
/// CLI session id — the same id the hooks hand CodeCat. That is the whole bridge
/// from a session row to the exact chat.
final class DesktopSessionIndexTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codecat-desktop-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ relative: String, _ text: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func testFindsTheRecordWhoseCLISessionMatches() throws {
        try write("org1/user1/local_aaa.json",
                  #"{"sessionId":"local_aaa","cliSessionId":"11111111-1111-1111-1111-111111111111"}"#)
        try write("org1/user1/local_bbb.json",
                  #"{"sessionId":"local_bbb","cliSessionId":"22222222-2222-2222-2222-222222222222"}"#)
        XCTAssertEqual(DesktopSessionIndex.localSessionID(
                           forCLISession: "22222222-2222-2222-2222-222222222222", root: root),
                       "local_bbb")
    }

    func testNoMatchIsNil() throws {
        try write("org1/user1/local_aaa.json",
                  #"{"sessionId":"local_aaa","cliSessionId":"11111111-1111-1111-1111-111111111111"}"#)
        XCTAssertNil(DesktopSessionIndex.localSessionID(forCLISession: "nope", root: root))
    }

    func testMissingRootIsNil() {
        let missing = root.appendingPathComponent("does-not-exist")
        XCTAssertNil(DesktopSessionIndex.localSessionID(forCLISession: "x", root: missing))
    }

    /// A broken record must not hide a good one next to it, and files that are not
    /// session records (whatever else the app drops in there) are skipped.
    func testMalformedAndForeignFilesAreSkipped() throws {
        try write("org1/user1/local_bad.json", "{not json")
        try write("org1/user1/notes.json", #"{"cliSessionId":"33333333-3333-3333-3333-333333333333"}"#)
        try write("org1/user1/local_good.json",
                  #"{"sessionId":"local_good","cliSessionId":"33333333-3333-3333-3333-333333333333"}"#)
        XCTAssertEqual(DesktopSessionIndex.localSessionID(
                           forCLISession: "33333333-3333-3333-3333-333333333333", root: root),
                       "local_good")
    }

    /// The record's own `sessionId` is authoritative; the file name is the fallback
    /// for a record that lacks it.
    func testFileNameIsTheFallbackWhenTheRecordHasNoSessionID() throws {
        try write("org1/user1/local_from-name.json",
                  #"{"cliSessionId":"44444444-4444-4444-4444-444444444444"}"#)
        XCTAssertEqual(DesktopSessionIndex.localSessionID(
                           forCLISession: "44444444-4444-4444-4444-444444444444", root: root),
                       "local_from-name")
    }

    func testDeepLinkOpensTheSessionInTheDesktopApp() {
        XCTAssertEqual(DesktopSessionIndex.deepLink(localSessionID: "local_abc").absoluteString,
                       "claude://code/continue?session=local_abc&source=codecat")
    }
}
