import XCTest
@testable import CodeCatCore

final class SessionStoreTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_756_400_000)

    func hook(_ name: String, id: String = "s1", cwd: String? = "/proj",
              message: String? = nil) -> HookEvent {
        HookEvent(hookEventName: name, sessionId: id, cwd: cwd, message: message)
    }

    func testSessionStartCreatesWorkingSession() {
        let store = SessionStore()
        store.apply(hook: hook("SessionStart"), now: t0)
        XCTAssertEqual(store.ordered.count, 1)
        XCTAssertEqual(store.ordered[0].status, .working)
        XCTAssertEqual(store.ordered[0].projectPath, "/proj")
        XCTAssertEqual(store.aggregate, .working(1))
    }

    func testNotificationWithPermissionMessageSetsWaitingPermission() {
        let store = SessionStore()
        store.apply(hook: hook("SessionStart"), now: t0)
        store.apply(hook: hook("Notification", message: "Claude needs your permission to use Bash"),
                    now: t0.addingTimeInterval(10))
        XCTAssertEqual(store.ordered[0].status, .waitingForYou(.permission))
        XCTAssertEqual(store.aggregate, .waiting(1))
    }

    func testNotificationWithoutPermissionWordSetsWaitingQuestion() {
        let store = SessionStore()
        store.apply(hook: hook("SessionStart"), now: t0)
        store.apply(hook: hook("Notification", message: "Claude is waiting for your input"),
                    now: t0.addingTimeInterval(10))
        XCTAssertEqual(store.ordered[0].status, .waitingForYou(.question))
    }

    func testStopSetsDoneAndSessionEndRemoves() {
        let store = SessionStore()
        store.apply(hook: hook("SessionStart"), now: t0)
        store.apply(hook: hook("Stop"), now: t0.addingTimeInterval(60))
        XCTAssertEqual(store.ordered[0].status, .done)
        XCTAssertEqual(store.aggregate, .done)
        store.apply(hook: hook("SessionEnd"), now: t0.addingTimeInterval(120))
        XCTAssertTrue(store.ordered.isEmpty)
        XCTAssertEqual(store.aggregate, .sleeping)
    }

    func testNewerTranscriptActivityResumesWorkingAndUpdatesDescription() {
        let store = SessionStore()
        store.apply(hook: hook("SessionStart"), now: t0)
        store.apply(hook: hook("Stop"), now: t0.addingTimeInterval(10))
        let act = TranscriptActivity(sessionId: "s1", projectPath: "/proj",
                                     description: "редактирует api.ts",
                                     timestamp: t0.addingTimeInterval(20))
        store.apply(activity: act)
        XCTAssertEqual(store.ordered[0].status, .working)
        XCTAssertEqual(store.ordered[0].activityDescription, "редактирует api.ts")
    }

    func testOlderTranscriptActivityDoesNotOverrideWaiting() {
        let store = SessionStore()
        store.apply(hook: hook("SessionStart"), now: t0)
        store.apply(hook: hook("Notification", message: "permission"), now: t0.addingTimeInterval(30))
        let stale = TranscriptActivity(sessionId: "s1", projectPath: "/proj",
                                       description: "думает",
                                       timestamp: t0.addingTimeInterval(29))
        store.apply(activity: stale)
        XCTAssertEqual(store.ordered[0].status, .waitingForYou(.permission))
    }

    func testActivityForUnknownSessionCreatesSession() {
        let store = SessionStore()
        let act = TranscriptActivity(sessionId: "s9", projectPath: "/p9",
                                     description: "думает", timestamp: t0)
        store.apply(activity: act)
        XCTAssertEqual(store.ordered.count, 1)
        XCTAssertEqual(store.ordered[0].status, .working)
    }

    func testAggregateWaitingBeatsProblem() {
        let store = SessionStore()
        store.apply(hook: hook("SessionStart", id: "a", cwd: "/a"), now: t0)
        store.apply(hook: hook("SessionStart", id: "c", cwd: "/c"), now: t0)
        store.apply(hook: hook("Notification", id: "c", message: "permission"),
                    now: t0.addingTimeInterval(299))
        store.reconcile(claudeProcessCount: 0, now: t0.addingTimeInterval(300))
        // a — упала (работала и протухла), c — ждёт (свежая активность в 299с);
        // приоритет у «ждёт»
        XCTAssertEqual(store.aggregate, .waiting(1))
    }

    func testReconcileMarksStaleSessionsCrashedWhenNoProcesses() {
        let store = SessionStore()
        store.apply(hook: hook("SessionStart"), now: t0)
        // активность была давно, процессов claude нет → сессия упала
        store.reconcile(claudeProcessCount: 0, now: t0.addingTimeInterval(300))
        XCTAssertEqual(store.ordered[0].status, .crashed)
        XCTAssertEqual(store.aggregate, .problem)
    }

    func testReconcileKeepsFreshSessionsEvenWithZeroProcesses() {
        let store = SessionStore()
        store.apply(hook: hook("SessionStart"), now: t0)
        // активность недавняя (< 120 c) → не трогаем, даже если pgrep никого не нашёл
        store.reconcile(claudeProcessCount: 0, now: t0.addingTimeInterval(60))
        XCTAssertEqual(store.ordered[0].status, .working)
    }

    func testExpireFinishedRemovesOldDoneSessions() {
        let store = SessionStore()
        store.apply(hook: hook("SessionStart"), now: t0)
        store.apply(hook: hook("Stop"), now: t0.addingTimeInterval(10))
        store.expireFinished(now: t0.addingTimeInterval(10 + 601), ttl: 600)
        XCTAssertTrue(store.ordered.isEmpty)
    }

    func testIdleHeuristicMarksQuietWorkingSessionAsWaitingIdle() {
        let store = SessionStore()
        store.apply(hook: hook("SessionStart"), now: t0)
        store.applyIdleHeuristic(now: t0.addingTimeInterval(120), threshold: 60)
        XCTAssertEqual(store.ordered[0].status, .waitingForYou(.idle))
    }

    // MARK: - anyWorking (Critical 1 & 3)

    func testAnyWorkingTrueWhileOneSessionWorksEvenIfAnotherWaits() {
        // Pins Critical 1: `aggregate` is a *display* value where waiting outranks
        // working, but power policy must read per-session status instead — one agent
        // waiting on the user must never cancel sleep-prevention for another agent that
        // is still actively working.
        let store = SessionStore()
        store.apply(hook: hook("SessionStart", id: "a", cwd: "/a"), now: t0)
        store.apply(hook: hook("SessionStart", id: "b", cwd: "/b"), now: t0)
        store.apply(hook: hook("Notification", id: "b", message: "permission"),
                    now: t0.addingTimeInterval(5))
        XCTAssertEqual(store.aggregate, .waiting(1), "aggregate — приоритет у waiting")
        XCTAssertTrue(store.anyWorking, "но agent 'a' всё ещё работает")
    }

    func testAnyWorkingFalseWhenAllSessionsWaitOrIdle() {
        let store = SessionStore()
        store.apply(hook: hook("SessionStart"), now: t0)
        store.apply(hook: hook("Notification", message: "permission"), now: t0.addingTimeInterval(5))
        XCTAssertFalse(store.anyWorking)
    }

    func testAnyWorkingTrueWhileWaitingIsIdleHeuristic() {
        // Pins Critical 3: `.waitingForYou(.idle)` is only a guess made by
        // `applyIdleHeuristic` (no hooks installed, transcript silent during a long tool
        // call) — it must still count as working for power policy, unlike a real
        // `.waitingForYou(.permission)`/`.waitingForYou(.question)` from an actual
        // Notification hook.
        let store = SessionStore()
        store.apply(hook: hook("SessionStart"), now: t0)
        store.applyIdleHeuristic(now: t0.addingTimeInterval(120), threshold: 60)
        XCTAssertEqual(store.ordered[0].status, .waitingForYou(.idle))
        XCTAssertTrue(store.anyWorking, ".idle — это догадка, а не реальный сигнал")
    }

    func testAnyWorkingFalseForRealPermissionWait() {
        let store = SessionStore()
        store.apply(hook: hook("SessionStart"), now: t0)
        store.apply(hook: hook("Notification", message: "needs your permission"),
                    now: t0.addingTimeInterval(5))
        XCTAssertEqual(store.ordered[0].status, .waitingForYou(.permission))
        XCTAssertFalse(store.anyWorking)
    }

    func testAnyWorkingFalseWhenEmpty() {
        XCTAssertFalse(SessionStore().anyWorking)
    }

    // MARK: - reconcile long-staleness (Critical 2)

    func testReconcileMarksLongStaleWorkingSessionCrashedEvenWithProcessesAlive() {
        // Pins Critical 2's slow path: a session SIGKILL'd while *other* `claude`
        // processes remain alive never sees `claudeProcessCount == 0`, so the fast path
        // (`staleAfter`) never fires. The long-staleness path must still catch it,
        // otherwise a `.working` session (and, via `anyWorking`, the sleep-prevention
        // assertion) would be held forever.
        let store = SessionStore()
        store.apply(hook: hook("SessionStart"), now: t0)
        store.reconcile(claudeProcessCount: 1, now: t0.addingTimeInterval(3 * 60 * 60),
                        longStaleAfter: 3 * 60 * 60)
        XCTAssertEqual(store.ordered[0].status, .crashed)
    }

    func testReconcileKeepsFreshSessionWithProcessesAliveUnderLongStaleThreshold() {
        // The mirror case: a session that is genuinely still busy (or genuinely left
        // waiting) must not be killed out from under the user just because some other
        // `claude` process happens to be running elsewhere.
        let store = SessionStore()
        store.apply(hook: hook("SessionStart"), now: t0)
        store.reconcile(claudeProcessCount: 1, now: t0.addingTimeInterval(60 * 60),
                        longStaleAfter: 3 * 60 * 60)
        XCTAssertEqual(store.ordered[0].status, .working)
    }

    func testReconcileMarksLongStaleWaitingForYouSessionCrashedEvenWithProcessesAlive() {
        // The mirror failure of Critical 2: an orphaned `.waitingForYou` session (e.g. the
        // terminal was closed while it waited on a permission prompt) must also age out,
        // not just `.working` ones.
        let store = SessionStore()
        store.apply(hook: hook("SessionStart"), now: t0)
        store.apply(hook: hook("Notification", message: "permission"), now: t0.addingTimeInterval(5))
        store.reconcile(claudeProcessCount: 1, now: t0.addingTimeInterval(5 + 3 * 60 * 60),
                        longStaleAfter: 3 * 60 * 60)
        XCTAssertEqual(store.ordered[0].status, .crashed)
    }

    func testReconcileDefaultLongStaleAfterIsOnTheOrderOfHours() {
        // Guards against a regression that quietly shrinks the default back down to
        // something that would kill a legitimately idle session: default must be well
        // above the old 120s fast-path threshold and expressed in hours, not minutes.
        let store = SessionStore()
        store.apply(hook: hook("SessionStart"), now: t0)
        store.reconcile(claudeProcessCount: 1, now: t0.addingTimeInterval(30 * 60))
        XCTAssertEqual(store.ordered[0].status, .working,
                       "30 минут не должно быть достаточно для default long-stale timeout")
    }
}
