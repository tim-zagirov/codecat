import XCTest
@testable import CodeCatCore

final class FileTailerTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testFirstSightSeedsToEndAndReturnsNothing() throws {
        let f = dir.appendingPathComponent("a.jsonl")
        try "old line\n".write(to: f, atomically: true, encoding: .utf8)
        let tailer = FileTailer()
        XCTAssertEqual(tailer.newLines(of: f), [])
    }

    func testReturnsOnlyAppendedCompleteLines() throws {
        let f = dir.appendingPathComponent("a.jsonl")
        try "old\n".write(to: f, atomically: true, encoding: .utf8)
        let tailer = FileTailer()
        _ = tailer.newLines(of: f) // seed
        let h = try FileHandle(forWritingTo: f)
        try h.seekToEnd()
        try h.write(contentsOf: "one\ntwo\npartial".data(using: .utf8)!)
        try h.close()
        XCTAssertEqual(tailer.newLines(of: f), ["one", "two"])
        // partial без \n не возвращается, но вернётся после дописывания
        let h2 = try FileHandle(forWritingTo: f)
        try h2.seekToEnd()
        try h2.write(contentsOf: " done\n".data(using: .utf8)!)
        try h2.close()
        XCTAssertEqual(tailer.newLines(of: f), ["partial done"])
    }

    func testMissingFileReturnsEmpty() {
        let tailer = FileTailer()
        XCTAssertEqual(tailer.newLines(of: dir.appendingPathComponent("nope.jsonl")), [])
    }
}
