import XCTest
import CoreServices
@testable import CodeCatCore

/// The transcript watcher: parsing FSEvents flags and the insurance walk.
///
/// FSEvents is not started in the tests — it is asynchronous, depends on how loaded
/// the machine is, and is not testable in itself. What is tested is everything that
/// does not depend on it: the rule "these flags mean events were lost", and the walk
/// that in such a situation (and on a timer) has to catch up on its own.
final class TranscriptWatcherTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codecat-watcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Flags

    /// Exactly the bug that lost whole batches of changes under load from several
    /// projects: when its queue overflows, FSEvents reports a directory path with one
    /// of these flags, and an "ends in .jsonl" check silently discarded it.
    func testFlagsThatMeanEventsWereLost() {
        for flag in [kFSEventStreamEventFlagMustScanSubDirs,
                     kFSEventStreamEventFlagUserDropped,
                     kFSEventStreamEventFlagKernelDropped,
                     kFSEventStreamEventFlagRootChanged] {
            XCTAssertTrue(TranscriptWatcher.meansLostEvents(FSEventStreamEventFlags(flag)),
                          "flag \(flag) means events were lost")
        }
    }

    func testOrdinaryFileEventFlagsDoNotTriggerARescan() {
        for flag in [kFSEventStreamEventFlagItemCreated,
                     kFSEventStreamEventFlagItemModified,
                     kFSEventStreamEventFlagItemRenamed,
                     kFSEventStreamEventFlagItemIsFile] {
            XCTAssertFalse(TranscriptWatcher.meansLostEvents(FSEventStreamEventFlags(flag)),
                           "flag \(flag) is an ordinary file event")
        }
        XCTAssertFalse(TranscriptWatcher.meansLostEvents(0))
    }

    /// Flags arrive mixed: "file changed" and "also, we lost some events" can appear in
    /// the same event.
    func testALostEventFlagIsRecognisedEvenMixedWithOrdinaryOnes() {
        let mixed = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagMustScanSubDirs)
        XCTAssertTrue(TranscriptWatcher.meansLostEvents(mixed))
    }

    // MARK: - The walk

    func testRescanDeliversLinesAppendedSinceTheLastPass() throws {
        let file = root.appendingPathComponent("s1.jsonl")
        try line(session: "s1", tool: "Bash").write(to: file, atomically: true, encoding: .utf8)

        let received = expectation(description: "activity arrived through the walk")
        let watcher = TranscriptWatcher(root: root) { activity in
            XCTAssertEqual(activity.sessionId, "s1")
            XCTAssertEqual(activity.description, "running a command")
            received.fulfill()
        }
        // The first pass gets acquainted with the file and stops at its end: other
        // sessions' history must not be replayed.
        watcher.rescan()
        try append(line(session: "s1", tool: "Bash"), to: file)
        watcher.rescan()

        wait(for: [received], timeout: 2)
        XCTAssertEqual(watcher.rescanCount, 2)
    }

    /// Subagent files live in nested directories — the walk has to be recursive, or a
    /// subagent's work would never be caught up on after events are lost.
    func testRescanReachesNestedSubagentTranscripts() throws {
        let nested = root.appendingPathComponent("proj/session/subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("agent-1.jsonl")
        try line(session: "s2", tool: "Read").write(to: file, atomically: true, encoding: .utf8)

        let received = expectation(description: "subagent activity arrived")
        let watcher = TranscriptWatcher(root: root) { activity in
            XCTAssertEqual(activity.sessionId, "s2")
            received.fulfill()
        }
        watcher.rescan()
        try append(line(session: "s2", tool: "Read"), to: file)
        watcher.rescan()

        wait(for: [received], timeout: 2)
    }

    /// The walk looks only at recently modified files: `~/.claude/projects` holds
    /// hundreds of transcripts from sessions finished long ago, and there is no reason
    /// to open them every twenty seconds.
    func testRescanSkipsFilesOlderThanTheWindow() throws {
        let stale = root.appendingPathComponent("old.jsonl")
        try line(session: "old", tool: "Bash").write(to: stale, atomically: true, encoding: .utf8)

        let watcher = TranscriptWatcher(root: root, rescanWindow: 60) { activity in
            XCTFail("an old file should not have been picked up by the walk: \(activity.sessionId)")
        }
        watcher.rescan()
        try append(line(session: "old", tool: "Bash"), to: stale)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: stale.path)
        watcher.rescan()

        // The callback goes to the main queue — let it turn over so the failure fires
        // if the file was read after all.
        let settled = expectation(description: "the main queue turned over")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 2)
    }

    /// A file the walk sees for the first time does not replay history — otherwise the
    /// very first pass would spit out a week of every session's conversation.
    func testRescanDoesNotReplayHistoryOfAFileItSeesForTheFirstTime() throws {
        let file = root.appendingPathComponent("s3.jsonl")
        let history = (0..<5).map { _ in line(session: "s3", tool: "Bash") }.joined()
        try history.write(to: file, atomically: true, encoding: .utf8)

        let watcher = TranscriptWatcher(root: root) { activity in
            XCTFail("history must not be replayed: \(activity.sessionId)")
        }
        watcher.rescan()

        let settled = expectation(description: "the main queue turned over")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 2)
    }

    // MARK: -

    private func line(session: String, tool: String) -> String {
        """
        {"type":"assistant","sessionId":"\(session)","timestamp":"2026-09-01T00:00:00.000Z",\
        "cwd":"/proj","message":{"content":[{"type":"tool_use","name":"\(tool)","input":{}}]}}

        """
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }
}

/// Recovering the picture at startup.
///
/// Before this, the app learned nothing about live sessions at launch: FSEvents
/// reports only the future, the walk starts a whole interval later, and FileTailer
/// sets its offset to the end the first time it meets a file. Measured on a live
/// machine — between 4 and 89 seconds of blindness on every restart.
final class TranscriptPrimingTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codecat-prime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeTranscript(_ name: String, lines: [String],
                                 modified: Date = Date()) throws -> URL {
        let url = root.appendingPathComponent("\(name).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    private func assistantLine(session: String, cwd: String, text: String) -> String {
        """
        {"type":"assistant","sessionId":"\(session)","cwd":"\(cwd)","timestamp":"2026-09-01T12:00:00.000Z","message":{"content":[{"type":"text","text":"\(text)"}]}}
        """
    }

    func testPrimingFindsASessionThatWasAlreadyRunning() throws {
        _ = try writeTranscript("live", lines: [
            assistantLine(session: "aaaa1111", cwd: "/Users/x/Projects/alpha", text: "thinking"),
        ])

        var seen: [TranscriptActivity] = []
        let expectation = expectation(description: "activity arrived")
        expectation.assertForOverFulfill = false
        let watcher = TranscriptWatcher(root: root) { activity in
            seen.append(activity); expectation.fulfill()
        }
        watcher.primeFromExistingTranscripts()
        wait(for: [expectation], timeout: 2)

        XCTAssertEqual(seen.first?.sessionId, "aaaa1111",
                       "a session already running must be found at once, not a minute later")
    }

    /// Old transcripts must not be picked up: otherwise the list after launch would
    /// hold sessions closed yesterday.
    func testPrimingIgnoresTranscriptsOlderThanTheWindow() throws {
        _ = try writeTranscript("ancient", lines: [
            assistantLine(session: "old00001", cwd: "/Users/x/Projects/beta", text: "long ago"),
        ], modified: Date().addingTimeInterval(-3600))

        var seen: [TranscriptActivity] = []
        let watcher = TranscriptWatcher(root: root, rescanWindow: 600) { seen.append($0) }
        watcher.primeFromExistingTranscripts()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        XCTAssertTrue(seen.isEmpty, "an hour-old transcript should not be picked up")
    }

    func testTailLinesReturnsWholeFileWhenSmall() throws {
        let url = try writeTranscript("small", lines: ["one", "two", "three"])
        XCTAssertEqual(TranscriptWatcher.tailLines(of: url, bytes: 64 * 1024),
                       ["one", "two", "three"])
    }

    /// A chunk started mid-file almost certainly begins with a truncated line — it has
    /// to be discarded, or the parser gets broken JSON.
    func testTailLinesDropsTheTruncatedFirstLine() throws {
        let url = try writeTranscript("big", lines: [
            String(repeating: "A", count: 500),
            String(repeating: "B", count: 50),
            String(repeating: "C", count: 50),
        ])
        let lines = TranscriptWatcher.tailLines(of: url, bytes: 120)
        XCTAssertFalse(lines.contains { $0.hasPrefix("A") },
                       "a truncated line must not reach the parser")
        XCTAssertEqual(lines.last, String(repeating: "C", count: 50))
    }

    func testTailLinesOnMissingFileIsEmptyNotFatal() {
        XCTAssertEqual(
            TranscriptWatcher.tailLines(of: root.appendingPathComponent("missing.jsonl"), bytes: 1024),
            [])
    }
}
