import XCTest
@testable import CodeCatCore

final class PathsTests: XCTestCase {
    func testSocketPathIsInsideAppSupportAndShortEnoughForUnixSocket() {
        let path = CodeCatPaths.socketURL.path
        XCTAssertTrue(path.hasSuffix("/CodeCat/codecat.sock"))
        // the sun_path limit on macOS is 104 bytes
        XCTAssertLessThan(path.utf8.count, 104)
    }

    func testClaudePaths() {
        XCTAssertTrue(CodeCatPaths.claudeSettings.path.hasSuffix("/.claude/settings.json"))
        XCTAssertTrue(CodeCatPaths.projectsRoot.path.hasSuffix("/.claude/projects"))
    }
}
