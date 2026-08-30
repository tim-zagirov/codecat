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

    // MARK: - The bundle the route was computed for

    /// The executor must be able to check that the pid it is about to activate still
    /// belongs to the app the route was computed for (a pid can be recycled), so every
    /// actionable route has to surface its bundle path.
    func testTerminalTabRouteExposesItsBundlePath() {
        let route = JumpRoute.terminalTab(bundleID: "com.apple.Terminal",
                                          bundlePath: "/System/Applications/Utilities/Terminal.app",
                                          pid: 4242, tty: "/dev/ttys001")
        XCTAssertEqual(route.bundlePath, "/System/Applications/Utilities/Terminal.app")
    }

    func testApplicationRouteExposesItsBundlePath() {
        XCTAssertEqual(JumpRoute.application(pid: 4242, bundlePath: "/Applications/Claude.app").bundlePath,
                       "/Applications/Claude.app")
    }

    func testUnavailableRouteHasNoBundlePath() {
        XCTAssertNil(JumpRoute.unavailable(reason: .hostGone).bundlePath)
    }

    /// Finding 7b: the hook can record a terminal bundle path and a tty while failing
    /// to read the bundle identifier (an unreadable Info.plist, an event from a build
    /// that did not send the field). A tab cannot be selected without knowing which
    /// terminal to script, so the route must degrade to the application.
    func testTerminalPathWithATtyButNoBundleIDRoutesToTheApplication() {
        let s = session(bundlePath: "/System/Applications/Utilities/Terminal.app",
                        bundleID: nil, tty: "/dev/ttys001")
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
            .automationDenied(fellBack: true), .automationDenied(fellBack: false),
            .tabNotFound(fellBack: true), .tabNotFound(fellBack: false),
            .hostGone, .failed("boom"),
        ]
        for outcome in outcomes {
            // `continue`, not `return`: one missing message must not hide the rest.
            guard let alert = JumpMessages.alert(for: outcome) else {
                XCTFail("no message for \(outcome)")
                continue
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
        let alert = JumpMessages.alert(for: .automationDenied(fellBack: true))
        XCTAssertTrue(alert!.body.contains("разрешение"))
        XCTAssertTrue(alert!.body.contains("Пока вывел приложение вперёд"))
    }

    /// The fallback activation can be refused (CodeCat is an accessory app behind a
    /// non-activating panel). A message claiming the app was brought forward when it
    /// was not is a lie the user can see through — it must say so plainly instead.
    func testAutomationDeniedWithoutAFallbackDoesNotClaimTheAppCameForward() {
        let alert = JumpMessages.alert(for: .automationDenied(fellBack: false))
        XCTAssertTrue(alert!.body.contains("разрешение"))
        XCTAssertFalse(alert!.body.contains("вывел приложение вперёд"))
        XCTAssertTrue(alert!.body.contains("не удалось"))
    }

    func testTabNotFoundMentionsTheClosedTab() {
        let alert = JumpMessages.alert(for: .tabNotFound(fellBack: true))
        XCTAssertTrue(alert!.body.contains("вкладк"))
        XCTAssertTrue(alert!.body.contains("Вывел приложение вперёд"))
    }

    func testTabNotFoundWithoutAFallbackDoesNotClaimTheAppCameForward() {
        let alert = JumpMessages.alert(for: .tabNotFound(fellBack: false))
        XCTAssertTrue(alert!.body.contains("вкладк"))
        XCTAssertFalse(alert!.body.contains("Вывел приложение вперёд"))
        XCTAssertTrue(alert!.body.contains("не удалось"))
    }

    /// Finding 4: a terminal that never answers must still produce a message, and it
    /// has to be a Russian one describing what actually happened.
    func testTimedOutTerminalHasItsOwnRussianDetail() {
        XCTAssertFalse(JumpMessages.terminalTimedOutDetail.isEmpty)
        XCTAssertTrue(JumpMessages.terminalTimedOutDetail
            .range(of: "\\p{Cyrillic}", options: .regularExpression) != nil)
        XCTAssertTrue(JumpMessages.alert(for: .failed(JumpMessages.terminalTimedOutDetail))!
            .body.contains(JumpMessages.terminalTimedOutDetail))
    }

    func testFailedCarriesTheUnderlyingDetail() {
        XCTAssertTrue(JumpMessages.alert(for: .failed("osascript error -1743"))!
            .body.contains("osascript error -1743"))
    }

    /// A terminal that never answered leaves the executor's serial queue blocked.
    /// The next jump must still reach the user rather than queueing invisibly behind
    /// it — a click that produces nothing at all is the one outcome the spec forbids.
    func testTerminalStillBusyDetailSaysWhetherTheAppCameForward() {
        let fellBack = JumpMessages.terminalStillBusyDetail(fellBack: true)
        let didNot = JumpMessages.terminalStillBusyDetail(fellBack: false)
        XCTAssertNotEqual(fellBack, didNot)
        for detail in [fellBack, didNot] {
            XCTAssertTrue(detail.range(of: "\\p{Cyrillic}", options: .regularExpression) != nil)
            XCTAssertTrue(detail.localizedCaseInsensitiveContains("предыдущ"))
        }
        XCTAssertTrue(fellBack.contains("вперёд"))
        XCTAssertTrue(didNot.contains("не удалось"))
    }

    func testRowHintsExplainWhyAJumpIsUnavailable() {
        XCTAssertTrue(JumpMessages.rowHint(for: .noHostRecorded).contains("до CodeCat"))
        XCTAssertFalse(JumpMessages.rowHint(for: .hostGone).isEmpty)
    }
}
