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
        // a partial with no \n is not returned, but will be once more is appended
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

    /// Finding 1: an atomic replacement (delete+rename, as
    /// String.write(to:atomically:true) does) changes the inode. If the new file is not
    /// smaller than the old offset, the naive `size < known` check does not fire and
    /// the tailer seeks into the middle of the new file, handing out a truncated
    /// fragment instead of lines from its beginning.
    func testAtomicReplacementLargerThanKnownOffsetIsReadFromStart() throws {
        let f = dir.appendingPathComponent("a.jsonl")
        try "old line one\nold line two\nold line three\n".write(to: f, atomically: true, encoding: .utf8)
        let tailer = FileTailer()
        XCTAssertEqual(tailer.newLines(of: f), []) // seed: known offset == old file size

        // An atomic replacement (temp file + rename) — new inode, size LARGER than the old known offset.
        let newContent = "brand new line A\nbrand new line B\nbrand new line C\nbrand new line D\n"
        XCTAssertGreaterThan(newContent.utf8.count, "old line one\nold line two\nold line three\n".utf8.count)
        try newContent.write(to: f, atomically: true, encoding: .utf8)

        XCTAssertEqual(tailer.newLines(of: f), [
            "brand new line A", "brand new line B", "brand new line C", "brand new line D",
        ])
    }

    /// Finding 1 (extra case): truncating a file to empty (same inode) and appending —
    /// the tailer has to notice the truncation (size < known) and return only the newly
    /// appended lines rather than getting confused by the old offset.
    func testTruncateToEmptyThenAppendReturnsNewLines() throws {
        let f = dir.appendingPathComponent("a.jsonl")
        try "old line\n".write(to: f, atomically: true, encoding: .utf8)
        let tailer = FileTailer()
        XCTAssertEqual(tailer.newLines(of: f), []) // seed, known offset == 9

        let h = try FileHandle(forWritingTo: f)
        try h.truncate(atOffset: 0)
        try h.close()
        XCTAssertEqual(tailer.newLines(of: f), []) // truncation noticed, offset reset

        let h2 = try FileHandle(forWritingTo: f)
        try h2.seekToEnd()
        try h2.write(contentsOf: "fresh one\nfresh two\n".data(using: .utf8)!)
        try h2.close()

        XCTAssertEqual(tailer.newLines(of: f), ["fresh one", "fresh two"])
    }

    /// Regression: in-place truncation to a NONZERO size (same inode) must not
    /// re-emit lines that were already delivered. Since the inode is unchanged,
    /// the surviving bytes are necessarily a prefix of what was already read,
    /// so re-reading from byte 0 would re-deliver already-seen lines.
    func testInPlaceTruncationToNonzeroSizeReturnsNoDuplicates() throws {
        let f = dir.appendingPathComponent("a.jsonl")
        try "".write(to: f, atomically: true, encoding: .utf8)
        let tailer = FileTailer()
        XCTAssertEqual(tailer.newLines(of: f), []) // seed, offset == 0

        let h = try FileHandle(forWritingTo: f)
        try h.seekToEnd()
        try h.write(contentsOf: "AAAA\nBBBB\nCCCC\n".data(using: .utf8)!)
        XCTAssertEqual(tailer.newLines(of: f), ["AAAA", "BBBB", "CCCC"]) // offset now 15

        // Truncate in place (same open handle/inode) to 10 bytes, leaving
        // "AAAA\nBBBB\n" — a strict prefix of what was already delivered.
        try h.truncate(atOffset: 10)
        try h.close()

        XCTAssertEqual(tailer.newLines(of: f), [])

        // Extend the regression check: append more data after the truncation
        // and confirm the tailer still tails it correctly (this is what
        // would have caught the buffered-partial bug below if the offset/
        // partial bookkeeping were wrong at the truncation boundary).
        let h2 = try FileHandle(forWritingTo: f)
        try h2.seekToEnd()
        try h2.write(contentsOf: "DDDD\n".data(using: .utf8)!)
        try h2.close()

        XCTAssertEqual(tailer.newLines(of: f), ["DDDD"])
    }

    /// Finding: truncation landing INSIDE a buffered partial (a line with no
    /// trailing "\n" yet, sitting in the tailer's internal buffer) must not
    /// silently drop the surviving prefix of that partial. The remembered
    /// `offset` counts bytes already READ, which includes the unterminated
    /// tail sitting in `partial` and never delivered to the caller. A naive
    /// "offset := new size, clear partial" reset discards that surviving
    /// prefix instead of keeping it, corrupting the next line delivered.
    ///
    /// Trace:
    /// 1. Write "AAAA\nBB" (7 bytes). newLines() returns ["AAAA"]; offset=7;
    ///    partial buffer holds "BB" (undelivered).
    /// 2. Truncate in place (same inode) to 6 bytes -> file is now "AAAA\nB".
    ///    The leading "B" at byte 5 was never delivered.
    /// 3. Append "B extra\n" -> real file content is "AAAA\nBB extra\n", so
    ///    the correct next line is "BB extra".
    func testTruncationInsideBufferedPartialPreservesSurvivingPrefix() throws {
        let f = dir.appendingPathComponent("a.jsonl")
        try "".write(to: f, atomically: true, encoding: .utf8)
        let tailer = FileTailer()
        XCTAssertEqual(tailer.newLines(of: f), []) // seed, offset == 0

        let h = try FileHandle(forWritingTo: f)
        try h.seekToEnd()
        try h.write(contentsOf: "AAAA\nBB".data(using: .utf8)!)
        XCTAssertEqual(tailer.newLines(of: f), ["AAAA"]) // offset now 7, partial buffer = "BB"

        // Truncate in place (same open handle/inode) to 6 bytes, leaving
        // "AAAA\nB" -- this lands strictly inside the buffered partial "BB".
        try h.truncate(atOffset: 6)
        try h.close()

        // Force the tailer to observe the shrink now (size 6 < known offset
        // 7), matching the concrete trace in the finding. Without this call,
        // the shrink-detection branch never runs at all once we append below
        // (size would already have grown back past the old offset), masking
        // the bug entirely.
        XCTAssertEqual(tailer.newLines(of: f), [])

        let h2 = try FileHandle(forWritingTo: f)
        try h2.seekToEnd()
        try h2.write(contentsOf: "B extra\n".data(using: .utf8)!)
        try h2.close()

        XCTAssertEqual(tailer.newLines(of: f), ["BB extra"])
    }
}
