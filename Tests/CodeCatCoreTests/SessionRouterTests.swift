import XCTest
@testable import CodeCatCore

final class SessionRouterTests: XCTestCase {

    private func session(hostPID: pid_t? = 4242,
                         bundlePath: String? = "/Applications/Claude.app",
                         bundleID: String? = "com.anthropic.claudefordesktop",
                         tty: String? = nil) -> Session {
        var s = Session(id: "s1", projectPath: "/tmp/p", status: .working,
                        activityDescription: "", startedAt: Date(), lastActivity: Date())
        s.hostPID = hostPID
        s.hostBundlePath = bundlePath
        s.hostBundleID = bundleID
        s.tty = tty
        return s
    }

    private let running: (pid_t) -> Bool = { _ in true }
    private let gone: (pid_t) -> Bool = { _ in false }

    /// Most precise route: a recognised terminal plus a tty means the exact tab.
    func testTerminalWithATtyRoutesToTheTab() {
        let s = session(bundlePath: "/System/Applications/Utilities/Terminal.app",
                        bundleID: "com.apple.Terminal", tty: "/dev/ttys001")
        XCTAssertEqual(SessionRouter.route(for: s, isHostRunning: running),
                       .terminalTab(bundleID: "com.apple.Terminal",
                                    bundlePath: "/System/Applications/Utilities/Terminal.app",
                                    pid: 4242, tty: "/dev/ttys001"))
    }

    func testITermIsRecognisedAsATerminal() {
        let s = session(bundlePath: "/Applications/iTerm.app",
                        bundleID: "com.googlecode.iterm2", tty: "/dev/ttys002")
        XCTAssertEqual(SessionRouter.route(for: s, isHostRunning: running),
                       .terminalTab(bundleID: "com.googlecode.iterm2",
                                    bundlePath: "/Applications/iTerm.app",
                                    pid: 4242, tty: "/dev/ttys002"))
    }

    /// A terminal without a tty cannot be aimed at a tab — bring the app forward.
    func testTerminalWithoutATtyFallsBackToTheApplication() {
        let s = session(bundlePath: "/System/Applications/Utilities/Terminal.app",
                        bundleID: "com.apple.Terminal", tty: nil)
        XCTAssertEqual(SessionRouter.route(for: s, isHostRunning: running),
                       .application(pid: 4242, bundlePath: "/System/Applications/Utilities/Terminal.app"))
    }

    /// A tty in an app that is not a supported terminal is not actionable: there is
    /// no scripting interface to select a tab with.
    func testTtyInAnUnsupportedHostFallsBackToTheApplication() {
        let s = session(tty: "/dev/ttys001")
        XCTAssertEqual(SessionRouter.route(for: s, isHostRunning: running),
                       .application(pid: 4242, bundlePath: "/Applications/Claude.app"))
    }

    func testDesktopAppRoutesToTheApplication() {
        XCTAssertEqual(SessionRouter.route(for: session(), isHostRunning: running),
                       .application(pid: 4242, bundlePath: "/Applications/Claude.app"))
    }

    /// A session the transcript watcher found on its own carries no route at all.
    func testSessionWithoutAHostIsUnavailable() {
        let s = session(hostPID: nil, bundlePath: nil, bundleID: nil)
        XCTAssertEqual(SessionRouter.route(for: s, isHostRunning: running),
                       .unavailable(reason: .noHostRecorded))
    }

    func testSessionWithABundleButNoPidIsUnavailable() {
        let s = session(hostPID: nil)
        XCTAssertEqual(SessionRouter.route(for: s, isHostRunning: running),
                       .unavailable(reason: .noHostRecorded))
    }

    func testSessionWithAPidButNoBundleIsUnavailable() {
        let s = session(bundlePath: nil, bundleID: nil)
        XCTAssertEqual(SessionRouter.route(for: s, isHostRunning: running),
                       .unavailable(reason: .noHostRecorded))
    }

    /// The owning app quit: the row must say so instead of offering a dead click.
    func testHostThatIsNoLongerRunningIsUnavailable() {
        XCTAssertEqual(SessionRouter.route(for: session(), isHostRunning: gone),
                       .unavailable(reason: .hostGone))
    }

    func testTerminalHostThatIsGoneIsUnavailableRatherThanATab() {
        let s = session(bundlePath: "/System/Applications/Utilities/Terminal.app",
                        bundleID: "com.apple.Terminal", tty: "/dev/ttys001")
        XCTAssertEqual(SessionRouter.route(for: s, isHostRunning: gone),
                       .unavailable(reason: .hostGone))
    }

    func testAnEmptyTtyStringIsTreatedAsNoTty() {
        let s = session(bundlePath: "/System/Applications/Utilities/Terminal.app",
                        bundleID: "com.apple.Terminal", tty: "")
        XCTAssertEqual(SessionRouter.route(for: s, isHostRunning: running),
                       .application(pid: 4242, bundlePath: "/System/Applications/Utilities/Terminal.app"))
    }

    // MARK: - Liveness of a real process

    func testThisProcessIsSeenAsRunning() {
        XCTAssertTrue(SessionRouter.isProcessRunning(getpid()))
    }

    func testAnImpossiblePidIsNotSeenAsRunning() {
        XCTAssertFalse(SessionRouter.isProcessRunning(-1))
    }
}

extension SessionRouterTests {

    /// A successful jump speaks for itself — the user is already looking at the
    /// destination, an alert would be noise.
    func testSuccessfulOutcomesProduceNoAlert() {
        XCTAssertNil(JumpMessages.alert(for: .switchedToTab))
        XCTAssertNil(JumpMessages.alert(for: .switchedToApplication))
    }

    /// Every failure is reported: the spec forbids silent refusals.
    func testEveryFailingOutcomeHasARussianMessage() {
        let outcomes: [JumpOutcome] = [
            .automationDenied, .tabNotFound, .hostGone, .failed("boom"),
        ]
        for outcome in outcomes {
            guard let alert = JumpMessages.alert(for: outcome) else {
                return XCTFail("no message for \(outcome)")
            }
            XCTAssertFalse(alert.title.isEmpty)
            XCTAssertFalse(alert.body.isEmpty)
            XCTAssertTrue(alert.body.range(of: "\\p{Cyrillic}", options: .regularExpression) != nil,
                          "message for \(outcome) is not in Russian: \(alert.body)")
        }
    }

    /// Denied automation is not the end of the road: the executor still brings the
    /// app forward, and the message must say what happened and what to do.
    func testAutomationDeniedMentionsThePermissionAndTheFallback() {
        let alert = JumpMessages.alert(for: .automationDenied)
        XCTAssertTrue(alert!.body.contains("разрешение"))
        XCTAssertTrue(alert!.body.contains("вперёд"))
    }

    func testTabNotFoundMentionsTheClosedTab() {
        XCTAssertTrue(JumpMessages.alert(for: .tabNotFound)!.body.contains("вкладк"))
    }

    func testFailedCarriesTheUnderlyingDetail() {
        XCTAssertTrue(JumpMessages.alert(for: .failed("osascript error -1743"))!
            .body.contains("osascript error -1743"))
    }

    func testRowHintsExplainWhyAJumpIsUnavailable() {
        XCTAssertTrue(JumpMessages.rowHint(for: .noHostRecorded).contains("до CodeCat"))
        XCTAssertFalse(JumpMessages.rowHint(for: .hostGone).isEmpty)
    }
}
