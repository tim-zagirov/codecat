import XCTest
@testable import CodeCatCore

final class LidHelperInstallTests: XCTestCase {
    // MARK: - appleScript(forScriptAt:)

    func testAppleScriptQuotesSimplePath() {
        let script = LidHelperInstall.appleScript(forScriptAt: "/Applications/CodeCat.app/Contents/Resources/install-lid-mode.sh")
        XCTAssertEqual(
            script,
            "do shell script \"bash '/Applications/CodeCat.app/Contents/Resources/install-lid-mode.sh'\" with administrator privileges")
    }

    func testAppleScriptHandlesPathWithSpaces() {
        let script = LidHelperInstall.appleScript(forScriptAt: "/Users/dev/My Applications/CodeCat.app/install-lid-mode.sh")
        // The path must stay a single shell argument, i.e. single-quoted.
        XCTAssertTrue(script.contains("bash '/Users/dev/My Applications/CodeCat.app/install-lid-mode.sh'"))
    }

    func testAppleScriptEscapesSingleQuoteInPath() {
        let script = LidHelperInstall.appleScript(forScriptAt: "/Users/dev/it's here/install-lid-mode.sh")
        // Shell-level quoting turns `'` into `'\''` (one backslash); that backslash then
        // goes through the AppleScript-literal escaping pass too, so it doubles up in the
        // final string — this is correct: `do shell script` un-escapes it back down to a
        // single backslash before the shell ever sees it.
        XCTAssertTrue(script.contains("'/Users/dev/it'\\\\''s here/install-lid-mode.sh'"))
    }

    func testAppleScriptEscapesDoubleQuoteInPathForAppleScriptLiteral() {
        let script = LidHelperInstall.appleScript(forScriptAt: "/Users/dev/weird\"path/install-lid-mode.sh")
        // The whole shell command sits inside a double-quoted AppleScript string,
        // so any `"` from the path must come through escaped as \" in that literal.
        XCTAssertTrue(script.contains("weird\\\"path"))
        XCTAssertFalse(script.contains("weird\"path"))
    }

    func testAppleScriptEscapesBackslashInPathForAppleScriptLiteral() {
        let script = LidHelperInstall.appleScript(forScriptAt: "/Users/dev/weird\\path/install-lid-mode.sh")
        XCTAssertTrue(script.contains("weird\\\\path"))
    }

    // MARK: - classify(status:output:)

    func testClassifySuccessOnZeroExit() {
        XCTAssertEqual(LidHelperInstall.classify(status: 0, output: ""), .success)
        // Exit 0 is success even if osascript printed something to stdout.
        XCTAssertEqual(
            LidHelperInstall.classify(status: 0, output: "CodeCat closed-lid mode installed"),
            .success)
    }

    func testClassifyCancelledOnDashOneTwentyEight() {
        let outcome = LidHelperInstall.classify(
            status: 1, output: "execution error: User canceled. (-128)")
        XCTAssertEqual(outcome, .cancelled)
    }

    func testClassifyCancelledOnEnglishCancelPhraseCaseInsensitive() {
        XCTAssertEqual(
            LidHelperInstall.classify(status: 1, output: "User Canceled."), .cancelled)
        XCTAssertEqual(
            LidHelperInstall.classify(status: 1, output: "the user cancelled the request"), .cancelled)
    }

    func testClassifyFailedWithDetailForOtherNonZeroExit() {
        let outcome = LidHelperInstall.classify(status: 1, output: "visudo: syntax error")
        XCTAssertEqual(outcome, .failed(detail: "exit code 1: visudo: syntax error"))
    }

    func testClassifyFailedWithNoOutputStillReportsStatus() {
        let outcome = LidHelperInstall.classify(status: 127, output: "")
        XCTAssertEqual(outcome, .failed(detail: "exit code 127"))
    }

    func testClassifyFailedTrimsWhitespace() {
        let outcome = LidHelperInstall.classify(status: 2, output: "  boom  \n")
        XCTAssertEqual(outcome, .failed(detail: "exit code 2: boom"))
    }
}
