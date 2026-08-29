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

    func testRunCommandHandlesLargeOutputWithoutDeadlock() {
        // Test that output larger than the pipe buffer (64 KB on macOS) is read correctly
        // without deadlock. This verifies that stdout is read before waitUntilExit().
        // Generate 200 KB of output: "hello\n" repeated ~33k times.
        // Run on background queue with timeout to fail fast on deadlock instead of hanging.

        let expectation = XCTestExpectation(description: "runCommand completes without deadlock")
        var resultOutput = ""

        DispatchQueue.global(qos: .default).async {
            resultOutput = ProcessScanner.runCommand(
                executablePath: "/bin/sh",
                arguments: ["-c", "yes hello | head -c 200000"]
            )
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)

        XCTAssert(resultOutput.count > 64000, "Output should be larger than pipe buffer")
        XCTAssertTrue(resultOutput.contains("hello"), "Output should contain expected content")
    }
}
