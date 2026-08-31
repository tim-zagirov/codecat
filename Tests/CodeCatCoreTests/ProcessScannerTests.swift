import XCTest
@testable import CodeCatCore

final class ProcessScannerTests: XCTestCase {
    func testCountMatchesNamesExactly() {
        let names = ["claude", "claude", "codecat-hook", "claude-code", "Claude"]
        XCTAssertEqual(ProcessScanner.count(of: "claude", in: names), 2,
                       "ни префиксы, ни другой регистр не считаются")
        XCTAssertEqual(ProcessScanner.count(of: "claude", in: []), 0)
    }

    /// Перечисление процессов должно действительно перечислять процессы: пустой
    /// массив из-за неверно посчитанного размера буфера выглядел бы как «во всей
    /// системе не запущено ни одного `claude`» — а это тот самый сигнал, по которому
    /// живые сессии помечаются оборвавшимися.
    func testLiveProcessListIsPopulatedAndIncludesLaunchd() {
        let names = ProcessScanner.runningProcessNames()
        XCTAssertGreaterThan(names.count, 10, "на macOS всегда работают десятки процессов")
        XCTAssertTrue(names.contains("launchd"), "pid 1 есть всегда")
    }

    func testLiveScanDoesNotCrash() {
        _ = ProcessScanner.claudeProcessCount() // просто не падает
    }

    func testIsProcessChecksTheExecutableNameNotJustExistence() {
        let tree = FakeTree(snapshots: [
            7: ProcessSnapshot(pid: 7, ppid: 1, executablePath: "/Apps/x.app/MacOS/claude", tty: nil),
            8: ProcessSnapshot(pid: 8, ppid: 1, executablePath: "/usr/bin/node", tty: nil),
        ])
        XCTAssertTrue(ProcessScanner.isProcess(7, provider: tree))
        XCTAssertFalse(ProcessScanner.isProcess(8, provider: tree),
                       "номер pid переиспользуется — по нему может отвечать чужой процесс")
        XCTAssertFalse(ProcessScanner.isProcess(9, provider: tree), "процесса нет")
        XCTAssertFalse(ProcessScanner.isProcess(0, provider: tree))
    }

    private struct FakeTree: ProcessTreeProviding {
        let snapshots: [pid_t: ProcessSnapshot]
        func snapshot(for pid: pid_t) -> ProcessSnapshot? { snapshots[pid] }
    }
}
