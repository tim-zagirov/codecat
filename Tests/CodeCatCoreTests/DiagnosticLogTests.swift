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
            message: "сокет поднят", timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(line, "2026-09-01 12:34:56.789 [app] сокет поднят\n")
    }

    /// Строка обязана оставаться одной строкой: хвост лога режется по `\n`, и
    /// многострочное сообщение (текст ошибки от macOS часто такой) поехало бы.
    func testNewlinesInMessageAreEscapedNotDropped() {
        let line = DiagnosticFormat.line(
            date: date("2026-09-01T00:00:00.000Z"), source: "app",
            message: "строка один\nстрока два", timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(line.filter { $0 == "\n" }.count, 1, "внутри записи не должно быть переводов строки")
        XCTAssertTrue(line.contains("строка один\\nстрока два"))
    }

    func testRotationTriggersAtLimitNotBefore() {
        XCTAssertFalse(DiagnosticFormat.shouldRotate(size: 999, limit: 1000))
        XCTAssertTrue(DiagnosticFormat.shouldRotate(size: 1000, limit: 1000))
        XCTAssertTrue(DiagnosticFormat.shouldRotate(size: 1001, limit: 1000))
    }

    func testTailReturnsLastLines() {
        let text = "один\nдва\nтри\nчетыре\n"
        XCTAssertEqual(DiagnosticFormat.tail(text, lines: 2), "три\nчетыре")
        XCTAssertEqual(DiagnosticFormat.tail(text, lines: 99), "один\nдва\nтри\nчетыре")
        XCTAssertEqual(DiagnosticFormat.tail(text, lines: 0), "")
    }

    /// Завершающий перевод строки не должен считаться за строку — иначе на каждый
    /// запрос отдавалась бы на одну реальную строку меньше.
    func testTailDoesNotCountTrailingNewlineAsALine() {
        XCTAssertEqual(DiagnosticFormat.tail("один\nдва\n", lines: 1), "два")
    }

    func testTailKeepsBlankLinesInsideLog() {
        XCTAssertEqual(DiagnosticFormat.tail("a\n\nb\n", lines: 3), "a\n\nb")
    }

    func testRedactCollapsesHomeButKeepsProjectNames() {
        let text = "cwd=/Users/tim/Projects/secret-app tty=/dev/ttys003"
        let out = DiagnosticFormat.redact(text, home: "/Users/tim")
        XCTAssertEqual(out, "cwd=~/Projects/secret-app tty=/dev/ttys003")
        XCTAssertTrue(out.contains("secret-app"), "имя проекта должно остаться — по нему и опознаётся сессия")
        XCTAssertFalse(out.contains("/Users/tim"), "логин не должен утечь в буфер обмена")
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
        log.write("первое")
        log.write("второе")
        log.close()
        let text = try! String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("первое"))
        XCTAssertTrue(text.contains("второе"))
        XCTAssertEqual(text.filter { $0 == "\n" }.count, 2)
    }

    /// Ровно тот случай, ради которого выбран O_APPEND: приложение и хук — разные
    /// процессы с разными дескрипторами одного файла. Здесь два дескриптора в одном
    /// процессе, что для ядра неотличимо, и ни одна строка не имеет права порваться.
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
        XCTAssertEqual(lines.count, 200, "должно быть ровно 200 целых строк")
        for line in lines {
            XCTAssertTrue(line.hasPrefix("20"), "строка начинается с метки времени, а не с обрывка чужой: \(line.prefix(40))")
            XCTAssertTrue(line.contains("[app]") || line.contains("[hook]"))
        }
    }

    func testRotateMovesFileAsideAndStartsFresh() {
        let url = dir.appendingPathComponent("codecat.log")
        let log = DiagnosticLog(url: url, source: "app")
        log.write(String(repeating: "y", count: 500))
        log.rotateIfNeeded(limit: 100)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("1").path),
                      "старый файл должен переехать в .1")
        log.write("после ротации")
        log.close()
        let text = try! String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("после ротации"))
        XCTAssertFalse(text.contains("yyy"), "новый файл должен начинаться пустым")
    }

    /// Главный риск ротации: дескриптор остаётся открытым на переименованный файл,
    /// и запись после ротации молча уходит в `.1` до самого перезапуска.
    func testWriteAfterRotationLandsInTheNewFileNotTheOldOne() {
        let url = dir.appendingPathComponent("codecat.log")
        let log = DiagnosticLog(url: url, source: "app")
        log.write(String(repeating: "z", count: 500))
        log.rotateIfNeeded(limit: 100)
        log.write("новая запись")
        log.close()

        let rotated = try! String(contentsOf: url.appendingPathExtension("1"), encoding: .utf8)
        XCTAssertFalse(rotated.contains("новая запись"), "запись после ротации не должна попасть в .1")
        XCTAssertTrue(try! String(contentsOf: url, encoding: .utf8).contains("новая запись"))
    }

    func testRotateDoesNothingBelowLimit() {
        let url = dir.appendingPathComponent("codecat.log")
        let log = DiagnosticLog(url: url, source: "app")
        log.write("коротко")
        log.rotateIfNeeded(limit: 1 << 20)
        log.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("1").path))
    }

    func testTailReachesIntoRotatedFileWhenCurrentIsShort() {
        let url = dir.appendingPathComponent("codecat.log")
        let log = DiagnosticLog(url: url, source: "app")
        log.write("старое один")
        log.write("старое два")
        log.rotateIfNeeded(limit: 1)
        log.write("новое")
        log.close()

        let tail = log.tail(lines: 3)
        XCTAssertTrue(tail.contains("старое два"), "хвост должен доставать из .1, когда текущий файл короче запроса")
        XCTAssertTrue(tail.contains("новое"))
        // Порядок хронологический: то, что было до ротации, идёт раньше.
        XCTAssertLessThan(tail.range(of: "старое два")!.lowerBound,
                          tail.range(of: "новое")!.lowerBound)
    }

    func testHookRefusesToWriteOnceFileIsHuge() {
        let url = dir.appendingPathComponent("codecat.log")
        let big = Data(repeating: 0x41, count: DiagnosticFormat.hookHardLimit + 1)
        try! big.write(to: url)
        let log = DiagnosticLog(url: url, source: "hook")
        XCTAssertFalse(log.writeIfWithinHardLimit("не должно записаться"),
                       "хук не ротирует, поэтому обязан замолчать на разросшемся файле")
        log.close()
    }

    func testWritingToUnopenableFileIsSilentNotFatal() {
        // Каталога нет — открыть нечего. Логирование не имеет права быть причиной
        // сбоя того, что оно логирует.
        let log = DiagnosticLog(url: dir.appendingPathComponent("нет/такого/codecat.log"),
                                source: "app")
        log.write("в никуда")
        XCTAssertEqual(log.tail(lines: 5), "")
        log.close()
    }
}
