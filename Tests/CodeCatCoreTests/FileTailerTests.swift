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

    /// Finding 1: атомарная замена файла (delete+rename, как делает
    /// String.write(to:atomically:true)) меняет inode. Если новый файл
    /// не меньше старого смещения, наивная проверка `size < known` не
    /// срабатывает, и тейлер сикает в середину нового файла, отдавая
    /// обрезанный фрагмент вместо строк с начала нового файла.
    func testAtomicReplacementLargerThanKnownOffsetIsReadFromStart() throws {
        let f = dir.appendingPathComponent("a.jsonl")
        try "old line one\nold line two\nold line three\n".write(to: f, atomically: true, encoding: .utf8)
        let tailer = FileTailer()
        XCTAssertEqual(tailer.newLines(of: f), []) // seed: known offset == old file size

        // Атомарная замена (temp file + rename) — новый inode, размер БОЛЬШЕ старого known offset.
        let newContent = "brand new line A\nbrand new line B\nbrand new line C\nbrand new line D\n"
        XCTAssertGreaterThan(newContent.utf8.count, "old line one\nold line two\nold line three\n".utf8.count)
        try newContent.write(to: f, atomically: true, encoding: .utf8)

        XCTAssertEqual(tailer.newLines(of: f), [
            "brand new line A", "brand new line B", "brand new line C", "brand new line D",
        ])
    }

    /// Finding 1 (доп. кейс): усечение файла до пустого (тот же inode) и
    /// дозапись — тейлер должен заметить усечение (size < known) и вернуть
    /// только вновь дописанные строки, а не путаться со старым смещением.
    func testTruncateToEmptyThenAppendReturnsNewLines() throws {
        let f = dir.appendingPathComponent("a.jsonl")
        try "old line\n".write(to: f, atomically: true, encoding: .utf8)
        let tailer = FileTailer()
        XCTAssertEqual(tailer.newLines(of: f), []) // seed, known offset == 9

        let h = try FileHandle(forWritingTo: f)
        try h.truncate(atOffset: 0)
        try h.close()
        XCTAssertEqual(tailer.newLines(of: f), []) // усечение замечено, offset сброшен

        let h2 = try FileHandle(forWritingTo: f)
        try h2.seekToEnd()
        try h2.write(contentsOf: "fresh one\nfresh two\n".data(using: .utf8)!)
        try h2.close()

        XCTAssertEqual(tailer.newLines(of: f), ["fresh one", "fresh two"])
    }
}
