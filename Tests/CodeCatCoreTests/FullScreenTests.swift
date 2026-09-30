import XCTest
@testable import CodeCatCore

final class FullScreenTests: XCTestCase {
    /// A 1512 × 982 built-in screen, in window-list coordinates (top-left origin).
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func window(pid: Int32 = 42, layer: Int = 0, _ bounds: CGRect) -> FullScreen.Window {
        FullScreen.Window(ownerPID: pid, layer: layer, bounds: bounds)
    }

    func testTheFrontmostAppsNormalWindowCoveringTheScreenIsFullScreen() {
        XCTAssertTrue(FullScreen.covers(screen: screen, windows: [window(screen)], frontmostPID: 42))
    }

    /// Another app's full-size window, a panel above the normal level (the menu bar
    /// is layer 24) and a window short of the menu bar are all ordinary desktops.
    func testAnythingElseIsNot() {
        XCTAssertFalse(FullScreen.covers(screen: screen, windows: [window(pid: 7, screen)], frontmostPID: 42))
        XCTAssertFalse(FullScreen.covers(screen: screen, windows: [window(layer: 24, screen)], frontmostPID: 42))
        XCTAssertFalse(FullScreen.covers(screen: screen,
                                         windows: [window(CGRect(x: 0, y: 33, width: 1512, height: 949))],
                                         frontmostPID: 42))
        XCTAssertFalse(FullScreen.covers(screen: screen, windows: [window(screen)], frontmostPID: nil))
    }

    /// A frontmost app in full screen on a second display leaves the notch screen an
    /// ordinary desktop: the island must not step aside for it.
    func testAFullScreenWindowOnAnotherDisplayDoesNotCoverTheNotchScreen() {
        let external = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        XCTAssertFalse(FullScreen.covers(screen: screen, windows: [window(external)], frontmostPID: 42))
        XCTAssertTrue(FullScreen.covers(screen: external, windows: [window(external)], frontmostPID: 42))
    }

    /// AppKit's screen frames have their origin at the main screen's bottom-left; the
    /// window list's at its top-left.
    func testScreenFramesConvertToWindowListCoordinates() {
        XCTAssertEqual(FullScreen.cgRect(forScreenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                         mainScreenHeight: 982), screen)
        // A 1920 × 1080 display placed above the main one.
        XCTAssertEqual(FullScreen.cgRect(forScreenFrame: CGRect(x: -200, y: 982, width: 1920, height: 1080),
                                         mainScreenHeight: 982),
                       CGRect(x: -200, y: -1080, width: 1920, height: 1080))
    }
}
