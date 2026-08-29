import XCTest
@testable import CodeCatCore

final class ProcessScannerTests: XCTestCase {
    func testCountProcessesParsesPgrepOutput() {
        XCTAssertEqual(ProcessScanner.count(fromPgrepOutput: "123\n456\n789\n"), 3)
        XCTAssertEqual(ProcessScanner.count(fromPgrepOutput: ""), 0)
        XCTAssertEqual(ProcessScanner.count(fromPgrepOutput: "\n"), 0)
    }

    func testLiveScanDoesNotCrash() {
        _ = ProcessScanner.claudeProcessCount() // просто не падает
    }
}
