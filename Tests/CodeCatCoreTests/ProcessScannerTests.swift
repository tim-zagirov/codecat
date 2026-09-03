import XCTest
@testable import CodeCatCore

final class ProcessScannerTests: XCTestCase {
    func testCountMatchesNamesExactly() {
        let names = ["claude", "claude", "codecat-hook", "claude-code", "Claude"]
        XCTAssertEqual(ProcessScanner.count(of: "claude", in: names), 2,
                       "neither prefixes nor a different case are counted")
        XCTAssertEqual(ProcessScanner.count(of: "claude", in: []), 0)
    }

    /// Enumerating processes has to actually enumerate them: an empty array caused by a
    /// mis-sized buffer would look like "not a single `claude` is running anywhere on
    /// the system" — and that is precisely the signal live sessions get marked as dead by.
    func testLiveProcessListIsPopulatedAndIncludesLaunchd() {
        let names = ProcessScanner.runningProcessNames()
        XCTAssertGreaterThan(names.count, 10, "macOS always has dozens of processes running")
        XCTAssertTrue(names.contains("launchd"), "pid 1 is always there")
    }

    func testLiveScanDoesNotCrash() {
        _ = ProcessScanner.claudeProcessCount() // simply does not crash
    }

    func testIsProcessChecksTheExecutableNameNotJustExistence() {
        let tree = FakeTree(snapshots: [
            7: ProcessSnapshot(pid: 7, ppid: 1, executablePath: "/Apps/x.app/MacOS/claude", tty: nil),
            8: ProcessSnapshot(pid: 8, ppid: 1, executablePath: "/usr/bin/node", tty: nil),
        ])
        XCTAssertTrue(ProcessScanner.isProcess(7, provider: tree))
        XCTAssertFalse(ProcessScanner.isProcess(8, provider: tree),
                       "pid numbers are reused — someone else's process may answer to it")
        XCTAssertFalse(ProcessScanner.isProcess(9, provider: tree), "no such process")
        XCTAssertFalse(ProcessScanner.isProcess(0, provider: tree))
    }

    private struct FakeTree: ProcessTreeProviding {
        let snapshots: [pid_t: ProcessSnapshot]
        func snapshot(for pid: pid_t) -> ProcessSnapshot? { snapshots[pid] }
    }
}
