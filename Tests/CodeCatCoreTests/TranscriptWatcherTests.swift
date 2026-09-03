import XCTest
import CoreServices
@testable import CodeCatCore

/// Наблюдатель за транскриптами: разбор флагов FSEvents и обход-страховка.
///
/// FSEvents в тестах не заводится — он асинхронный, зависит от нагрузки на машину и
/// сам по себе не проверяем. Проверяется то, что от него не зависит: правило «эти
/// флаги значат, что события потерялись» и обход, который в такой ситуации (а также
/// по таймеру) обязан догнать состояние сам.
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

    // MARK: - Флаги

    /// Ровно тот баг, из-за которого под нагрузкой от нескольких проектов терялись
    /// целые пачки изменений: при переполнении очереди FSEvents отдаёт путь к
    /// каталогу с одним из этих флагов, а проверка «оканчивается на .jsonl» молча
    /// его отбрасывала.
    func testFlagsThatMeanEventsWereLost() {
        for flag in [kFSEventStreamEventFlagMustScanSubDirs,
                     kFSEventStreamEventFlagUserDropped,
                     kFSEventStreamEventFlagKernelDropped,
                     kFSEventStreamEventFlagRootChanged] {
            XCTAssertTrue(TranscriptWatcher.meansLostEvents(FSEventStreamEventFlags(flag)),
                          "флаг \(flag) означает потерю событий")
        }
    }

    func testOrdinaryFileEventFlagsDoNotTriggerARescan() {
        for flag in [kFSEventStreamEventFlagItemCreated,
                     kFSEventStreamEventFlagItemModified,
                     kFSEventStreamEventFlagItemRenamed,
                     kFSEventStreamEventFlagItemIsFile] {
            XCTAssertFalse(TranscriptWatcher.meansLostEvents(FSEventStreamEventFlags(flag)),
                           "флаг \(flag) — обычное событие о файле")
        }
        XCTAssertFalse(TranscriptWatcher.meansLostEvents(0))
    }

    /// Флаги приходят смесью: «файл изменён» и «а ещё часть событий мы потеряли»
    /// могут стоять в одном событии.
    func testALostEventFlagIsRecognisedEvenMixedWithOrdinaryOnes() {
        let mixed = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagMustScanSubDirs)
        XCTAssertTrue(TranscriptWatcher.meansLostEvents(mixed))
    }

    // MARK: - Обход

    func testRescanDeliversLinesAppendedSinceTheLastPass() throws {
        let file = root.appendingPathComponent("s1.jsonl")
        try line(session: "s1", tool: "Bash").write(to: file, atomically: true, encoding: .utf8)

        let received = expectation(description: "активность доехала обходом")
        let watcher = TranscriptWatcher(root: root) { activity in
            XCTAssertEqual(activity.sessionId, "s1")
            XCTAssertEqual(activity.description, "running a command")
            received.fulfill()
        }
        // Первый проход знакомится с файлом и встаёт на его конец: историю чужих
        // сессий переигрывать нельзя.
        watcher.rescan()
        try append(line(session: "s1", tool: "Bash"), to: file)
        watcher.rescan()

        wait(for: [received], timeout: 2)
        XCTAssertEqual(watcher.rescanCount, 2)
    }

    /// Файлы субагентов лежат во вложенных каталогах — обход обязан быть
    /// рекурсивным, иначе после потери событий работа субагента не догонится.
    func testRescanReachesNestedSubagentTranscripts() throws {
        let nested = root.appendingPathComponent("proj/session/subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("agent-1.jsonl")
        try line(session: "s2", tool: "Read").write(to: file, atomically: true, encoding: .utf8)

        let received = expectation(description: "активность субагента доехала")
        let watcher = TranscriptWatcher(root: root) { activity in
            XCTAssertEqual(activity.sessionId, "s2")
            received.fulfill()
        }
        watcher.rescan()
        try append(line(session: "s2", tool: "Read"), to: file)
        watcher.rescan()

        wait(for: [received], timeout: 2)
    }

    /// Обход смотрит только недавно изменённые файлы: в `~/.claude/projects` лежат
    /// сотни транскриптов давно законченных сессий, и открывать их каждые двадцать
    /// секунд незачем.
    func testRescanSkipsFilesOlderThanTheWindow() throws {
        let stale = root.appendingPathComponent("old.jsonl")
        try line(session: "old", tool: "Bash").write(to: stale, atomically: true, encoding: .utf8)

        let watcher = TranscriptWatcher(root: root, rescanWindow: 60) { activity in
            XCTFail("старый файл не должен был попасть в обход: \(activity.sessionId)")
        }
        watcher.rescan()
        try append(line(session: "old", tool: "Bash"), to: stale)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: stale.path)
        watcher.rescan()

        // Коллбэк уходит на главную очередь — даём ей прокрутиться, чтобы падение
        // сработало, если файл всё-таки прочитали.
        let settled = expectation(description: "главная очередь прокрутилась")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 2)
    }

    /// Файл, который обход видит впервые, историю не переигрывает — иначе первый же
    /// проход выплюнул бы всю переписку всех сессий за неделю.
    func testRescanDoesNotReplayHistoryOfAFileItSeesForTheFirstTime() throws {
        let file = root.appendingPathComponent("s3.jsonl")
        let history = (0..<5).map { _ in line(session: "s3", tool: "Bash") }.joined()
        try history.write(to: file, atomically: true, encoding: .utf8)

        let watcher = TranscriptWatcher(root: root) { activity in
            XCTFail("история не должна переигрываться: \(activity.sessionId)")
        }
        watcher.rescan()

        let settled = expectation(description: "главная очередь прокрутилась")
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

/// Восстановление картины при запуске.
///
/// До этого приложение при старте не узнавало о живых сессиях никак: FSEvents
/// сообщает только о будущем, обход заводится через целый интервал, а FileTailer
/// при первой встрече с файлом ставит смещение в конец. Замер на живой машине —
/// от 4 до 89 секунд слепоты на каждом перезапуске.
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
            assistantLine(session: "aaaa1111", cwd: "/Users/x/Projects/alpha", text: "думаю"),
        ])

        var seen: [TranscriptActivity] = []
        let expectation = expectation(description: "активность доехала")
        expectation.assertForOverFulfill = false
        let watcher = TranscriptWatcher(root: root) { activity in
            seen.append(activity); expectation.fulfill()
        }
        watcher.primeFromExistingTranscripts()
        wait(for: [expectation], timeout: 2)

        XCTAssertEqual(seen.first?.sessionId, "aaaa1111",
                       "уже идущая сессия обязана найтись сразу, а не через минуту")
    }

    /// Старые транскрипты подниматься не должны: иначе после запуска в списке
    /// оказались бы сессии, закрытые вчера.
    func testPrimingIgnoresTranscriptsOlderThanTheWindow() throws {
        _ = try writeTranscript("ancient", lines: [
            assistantLine(session: "old00001", cwd: "/Users/x/Projects/beta", text: "давно"),
        ], modified: Date().addingTimeInterval(-3600))

        var seen: [TranscriptActivity] = []
        let watcher = TranscriptWatcher(root: root, rescanWindow: 600) { seen.append($0) }
        watcher.primeFromExistingTranscripts()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        XCTAssertTrue(seen.isEmpty, "транскрипт часовой давности поднимать не надо")
    }

    func testTailLinesReturnsWholeFileWhenSmall() throws {
        let url = try writeTranscript("small", lines: ["один", "два", "три"])
        XCTAssertEqual(TranscriptWatcher.tailLines(of: url, bytes: 64 * 1024),
                       ["один", "два", "три"])
    }

    /// Кусок, начатый с середины файла, почти наверняка начинается с обрезанной
    /// строки — её надо отбросить, иначе парсер получит битый JSON.
    func testTailLinesDropsTheTruncatedFirstLine() throws {
        let url = try writeTranscript("big", lines: [
            String(repeating: "A", count: 500),
            String(repeating: "B", count: 50),
            String(repeating: "C", count: 50),
        ])
        let lines = TranscriptWatcher.tailLines(of: url, bytes: 120)
        XCTAssertFalse(lines.contains { $0.hasPrefix("A") },
                       "обрезанная строка не должна попасть в разбор")
        XCTAssertEqual(lines.last, String(repeating: "C", count: 50))
    }

    func testTailLinesOnMissingFileIsEmptyNotFatal() {
        XCTAssertEqual(
            TranscriptWatcher.tailLines(of: root.appendingPathComponent("нет.jsonl"), bytes: 1024),
            [])
    }
}
