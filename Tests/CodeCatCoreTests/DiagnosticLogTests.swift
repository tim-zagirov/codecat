import XCTest
@testable import CodeCatCore

final class DiagnosticFormatTests: XCTestCase {

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: iso)!
    }

    func testLineHasStampSourceAndMessage() {
        let line = DiagnosticFormat.line(
            date: date("2026-09-01T12:34:56.789Z"), source: "app",
            message: "socket is up", timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(line, "2026-09-01 12:34:56.789 [app] socket is up\n")
    }

    /// A record has to stay one line: the log's tail is split on `\n`, and a multi-line
    /// message (macOS error text often is one) would throw it off.
    func testNewlinesInMessageAreEscapedNotDropped() {
        let line = DiagnosticFormat.line(
            date: date("2026-09-01T00:00:00.000Z"), source: "app",
            message: "line one\nline two", timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(line.filter { $0 == "\n" }.count, 1, "a record must contain no newlines")
        XCTAssertTrue(line.contains("line one\\nline two"))
    }

    func testRotationTriggersAtLimitNotBefore() {
        XCTAssertFalse(DiagnosticFormat.shouldRotate(size: 999, limit: 1000))
        XCTAssertTrue(DiagnosticFormat.shouldRotate(size: 1000, limit: 1000))
        XCTAssertTrue(DiagnosticFormat.shouldRotate(size: 1001, limit: 1000))
    }

    func testTailReturnsLastLines() {
        let text = "one\ntwo\nthree\nfour\n"
        XCTAssertEqual(DiagnosticFormat.tail(text, lines: 2), "three\nfour")
        XCTAssertEqual(DiagnosticFormat.tail(text, lines: 99), "one\ntwo\nthree\nfour")
        XCTAssertEqual(DiagnosticFormat.tail(text, lines: 0), "")
    }

    /// A trailing newline must not count as a line — otherwise every request would
    /// return one real line fewer than asked.
    func testTailDoesNotCountTrailingNewlineAsALine() {
        XCTAssertEqual(DiagnosticFormat.tail("one\ntwo\n", lines: 1), "two")
    }

    func testTailKeepsBlankLinesInsideLog() {
        XCTAssertEqual(DiagnosticFormat.tail("a\n\nb\n", lines: 3), "a\n\nb")
    }

    func testRedactCollapsesHomeButKeepsProjectNames() {
        let text = "cwd=/Users/tim/Projects/secret-app tty=/dev/ttys003"
        let out = DiagnosticFormat.redact(text, home: "/Users/tim")
        XCTAssertEqual(out, "cwd=~/Projects/secret-app tty=/dev/ttys003")
        XCTAssertTrue(out.contains("secret-app"), "the project name has to stay — it is what identifies the session")
        XCTAssertFalse(out.contains("/Users/tim"), "the login must not leak into the clipboard")
    }

    func testRedactHandlesTrailingSlashAndEmptyHome() {
        XCTAssertEqual(DiagnosticFormat.redact("/Users/tim/x", home: "/Users/tim/"), "~/x")
        XCTAssertEqual(DiagnosticFormat.redact("/Users/tim/x", home: ""), "/Users/tim/x")
    }
}

final class DiagnosticLogFileTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codecat-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testWritesAppendRatherThanOverwrite() {
        let url = dir.appendingPathComponent("codecat.log")
        let log = DiagnosticLog(url: url, source: "app")
        log.write("first")
        log.write("second")
        log.close()
        let text = try! String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("first"))
        XCTAssertTrue(text.contains("second"))
        XCTAssertEqual(text.filter { $0 == "\n" }.count, 2)
    }

    /// Exactly the case O_APPEND was chosen for: the app and the hook are different
    /// processes with different descriptors on one file. Here there are two descriptors
    /// in one process, which the kernel cannot tell apart, and no line may be torn.
    func testTwoWritersDoNotTearEachOthersLines() {
        let url = dir.appendingPathComponent("codecat.log")
        let a = DiagnosticLog(url: url, source: "app")
        let b = DiagnosticLog(url: url, source: "hook")
        let group = DispatchGroup()
        for i in 0..<200 {
            DispatchQueue.global().async(group: group) {
                (i % 2 == 0 ? a : b).write(String(repeating: "x", count: 100) + "-\(i)")
            }
        }
        group.wait()
        a.close(); b.close()

        let text = try! String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 200, "there must be exactly 200 whole lines")
        for line in lines {
            XCTAssertTrue(line.hasPrefix("20"), "a line starts with a timestamp, not with a fragment of someone else's: \(line.prefix(40))")
            XCTAssertTrue(line.contains("[app]") || line.contains("[hook]"))
        }
    }

    func testRotateMovesFileAsideAndStartsFresh() {
        let url = dir.appendingPathComponent("codecat.log")
        let log = DiagnosticLog(url: url, source: "app")
        log.write(String(repeating: "y", count: 500))
        log.rotateIfNeeded(limit: 100)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("1").path),
                      "the old file must move to .1")
        log.write("after rotation")
        log.close()
        let text = try! String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("after rotation"))
        XCTAssertFalse(text.contains("yyy"), "the new file must start empty")
    }

    /// Rotation's main risk: the descriptor stays open on the renamed file, and writes
    /// after rotation silently go to `.1` until the process is restarted.
    func testWriteAfterRotationLandsInTheNewFileNotTheOldOne() {
        let url = dir.appendingPathComponent("codecat.log")
        let log = DiagnosticLog(url: url, source: "app")
        log.write(String(repeating: "z", count: 500))
        log.rotateIfNeeded(limit: 100)
        log.write("new record")
        log.close()

        let rotated = try! String(contentsOf: url.appendingPathExtension("1"), encoding: .utf8)
        XCTAssertFalse(rotated.contains("new record"), "a write after rotation must not land in .1")
        XCTAssertTrue(try! String(contentsOf: url, encoding: .utf8).contains("new record"))
    }

    func testRotateDoesNothingBelowLimit() {
        let url = dir.appendingPathComponent("codecat.log")
        let log = DiagnosticLog(url: url, source: "app")
        log.write("short")
        log.rotateIfNeeded(limit: 1 << 20)
        log.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("1").path))
    }

    func testTailReachesIntoRotatedFileWhenCurrentIsShort() {
        let url = dir.appendingPathComponent("codecat.log")
        let log = DiagnosticLog(url: url, source: "app")
        log.write("old one")
        log.write("old two")
        log.rotateIfNeeded(limit: 1)
        log.write("new")
        log.close()

        let tail = log.tail(lines: 3)
        XCTAssertTrue(tail.contains("old two"), "the tail must reach into .1 when the current file is shorter than requested")
        XCTAssertTrue(tail.contains("new"))
        // Chronological order: what came before the rotation comes first.
        XCTAssertLessThan(tail.range(of: "old two")!.lowerBound,
                          tail.range(of: "new")!.lowerBound)
    }

    func testHookRefusesToWriteOnceFileIsHuge() {
        let url = dir.appendingPathComponent("codecat.log")
        let big = Data(repeating: 0x41, count: DiagnosticFormat.hookHardLimit + 1)
        try! big.write(to: url)
        let log = DiagnosticLog(url: url, source: "hook")
        XCTAssertFalse(log.writeIfWithinHardLimit("must not be written"),
                       "the hook does not rotate, so it has to fall silent on a grown file")
        log.close()
    }

    func testWritingToUnopenableFileIsSilentNotFatal() {
        // The directory does not exist — there is nothing to open. Logging has no right
        // to be the cause of a failure in what it logs.
        let log = DiagnosticLog(url: dir.appendingPathComponent("no/such/codecat.log"),
                                source: "app")
        log.write("into the void")
        XCTAssertEqual(log.tail(lines: 5), "")
        log.close()
    }
}
