import XCTest
@testable import CodeCatCore

final class TerminalJumpScriptTests: XCTestCase {

    // MARK: - Escaping into an AppleScript string literal

    func testPlainValueIsUnchanged() {
        XCTAssertEqual(TerminalJumpScript.escaped("/dev/ttys001"), "/dev/ttys001")
    }

    func testDoubleQuoteIsEscaped() {
        XCTAssertEqual(TerminalJumpScript.escaped(#"a"b"#), #"a\"b"#)
    }

    func testBackslashIsEscaped() {
        XCTAssertEqual(TerminalJumpScript.escaped(#"a\b"#), #"a\\b"#)
    }

    /// Backslashes must be doubled before quotes are escaped, otherwise the
    /// backslash inserted for the quote gets doubled too and the literal breaks.
    func testBackslashBeforeQuoteIsEscapedInTheRightOrder() {
        XCTAssertEqual(TerminalJumpScript.escaped(#"a\"b"#), #"a\\\"b"#)
    }

    func testSpacesSurviveEscaping() {
        XCTAssertEqual(TerminalJumpScript.escaped("/dev/tty with space"),
                       "/dev/tty with space")
    }

    // MARK: - Script contents

    func testTerminalScriptTargetsTerminalAndTheGivenTty() {
        let script = TerminalJumpScript.script(bundleID: "com.apple.Terminal", tty: "/dev/ttys001")
        XCTAssertNotNil(script)
        XCTAssertTrue(script!.contains(#"id "com.apple.Terminal""#))
        XCTAssertTrue(script!.contains(#""/dev/ttys001""#))
        XCTAssertTrue(script!.contains(TerminalJumpScript.successMarker))
        XCTAssertTrue(script!.contains(TerminalJumpScript.notFoundMarker))
    }

    func testITermScriptTargetsITerm() {
        let script = TerminalJumpScript.script(bundleID: "com.googlecode.iterm2", tty: "/dev/ttys002")
        XCTAssertNotNil(script)
        XCTAssertTrue(script!.contains(#"id "com.googlecode.iterm2""#))
        XCTAssertTrue(script!.contains(#""/dev/ttys002""#))
    }

    func testUnknownTerminalHasNoScript() {
        XCTAssertNil(TerminalJumpScript.script(bundleID: "com.example.other", tty: "/dev/ttys001"))
    }

    /// A tty containing a quote must not be able to close the literal and inject
    /// AppleScript of its own.
    func testHostileTtyCannotEscapeTheStringLiteral() {
        let script = TerminalJumpScript.script(
            bundleID: "com.apple.Terminal", tty: #"/dev/x" & (do shell script "echo pwned") & ""#)
        XCTAssertNotNil(script)
        XCTAssertFalse(script!.contains(#"& (do shell script "echo pwned")"#))
        XCTAssertTrue(script!.contains(#"\""#))
    }

    /// Every bundle id the router can route to a tab must have a script, or a jump
    /// would silently have nowhere to go.
    func testEveryRecognisedTerminalHasAScript() {
        for id in SessionRouter.terminalBundleIDs {
            XCTAssertNotNil(TerminalJumpScript.script(bundleID: id, tty: "/dev/ttys001"),
                            "no script for \(id)")
        }
    }
}
