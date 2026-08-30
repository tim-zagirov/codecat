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

    // MARK: - reconcile + expireFinished interaction (regression)

    func testLongStaleCrashViaReconcileSurvivesSameTickExpireFinished() {
        // The regression this pins: the app's maintenance timer calls reconcile() then
        // expireFinished() back-to-back with the same `now` every tick. Before the fix,
        // reconcile() flipped a long-stale session to .crashed without touching
        // lastActivity, and expireFinished() measured its TTL from that same stale
        // lastActivity — so a session that had been quiet for longer than `ttl` (but
        // less than `longStaleAfter`) was deleted in the very same tick it was first
        // marked crashed, before the UI ever got to show it as a problem.
        //
        // Here the session goes quiet at t0, another `claude` process stays alive the
        // whole time (claudeProcessCount: 1) so only the long-stale path can catch it,
        // and by the time longStaleAfter elapses, way more than ttl (600s) has already
        // passed since lastActivity — exactly the scenario that used to vanish silently.
        let store = SessionStore()
        store.apply(hook: hook("SessionStart"), now: t0)
        let crashTime = t0.addingTimeInterval(4 * 60 * 60) // longStaleAfter default
        store.reconcile(claudeProcessCount: 1, now: crashTime)
        store.expireFinished(now: crashTime)
        XCTAssertEqual(store.ordered.count, 1, "should still be visible right after crashing")
        XCTAssertEqual(store.ordered[0].status, .crashed)
        XCTAssertEqual(store.aggregate, .problem)
    }

    func testLongStaleCrashedSessionExpiresTtlAfterItCrashedNotAfterLastActivity() {
        // Mirror of the above: the crashed session must eventually go away, but the
        // clock for that should start at finishedAt (when reconcile marked it crashed),
        // not at lastActivity (which by then is old news).
        let store = SessionStore()
        store.apply(hook: hook("SessionStart"), now: t0)
        let crashTime = t0.addingTimeInterval(4 * 60 * 60)
        store.reconcile(claudeProcessCount: 1, now: crashTime)
        // Just under ttl since it crashed: still present, even though it's been quiet
        // (by lastActivity) for far longer than ttl.
        store.expireFinished(now: crashTime.addingTimeInterval(599))
        XCTAssertEqual(store.ordered.count, 1, "not yet expired — under 600s since it crashed")
        // Just over ttl since it crashed: now it goes.
        store.expireFinished(now: crashTime.addingTimeInterval(601))
        XCTAssertTrue(store.ordered.isEmpty, "expired — over 600s since it crashed")
    }

    func testFastPathCrashedSessionSurvivesSameTickExpireFinishedThenExpiresOnSchedule() {
        // Pins the pre-existing fast path (no claude processes, staleAfter=120 < ttl=600)
        // stays correct under the fix: a session should still be visible as crashed for
        // the full ttl window after crashing, not just for a few seconds.
        let store = SessionStore()
        store.apply(hook: hook("SessionStart"), now: t0)
        let crashTime = t0.addingTimeInterval(120) // staleAfter default, no processes
        store.reconcile(claudeProcessCount: 0, now: crashTime)
        store.expireFinished(now: crashTime)
        XCTAssertEqual(store.ordered.count, 1, "crashed session must survive the same tick")
        XCTAssertEqual(store.ordered[0].status, .crashed)

        // Still present partway through the ttl window measured from when it crashed.
        store.expireFinished(now: crashTime.addingTimeInterval(300))
        XCTAssertEqual(store.ordered.count, 1)

        // Gone once ttl has elapsed since it crashed.
        store.expireFinished(now: crashTime.addingTimeInterval(601))
        XCTAssertTrue(store.ordered.isEmpty)
    }

    func testDoneSessionExpiryIsMeasuredFromWhenItFinished() {
        // A session that goes quiet for a long while (heartbeats keep lastActivity
        // moving, or it simply sat there before Stop arrived) and only then finishes
        // must still get the full ttl window from the Stop, not have its clock
        // back-dated to some earlier lastActivity.
        let store = SessionStore()
        store.apply(hook: hook("SessionStart"), now: t0)
        let activity = TranscriptActivity(sessionId: "s1", projectPath: "/proj",
                                          description: "работает",
                                          timestamp: t0.addingTimeInterval(3 * 60 * 60))
        store.apply(activity: activity)
        let doneTime = t0.addingTimeInterval(3 * 60 * 60 + 10)
        store.apply(hook: hook("Stop"), now: doneTime)
        XCTAssertEqual(store.ordered[0].status, .done)

        // 599s after it finished (not from lastActivity, which is 10s earlier): still there.
        store.expireFinished(now: doneTime.addingTimeInterval(599))
        XCTAssertEqual(store.ordered.count, 1)

        // 601s after it finished: expired.
        store.expireFinished(now: doneTime.addingTimeInterval(601))
        XCTAssertTrue(store.ordered.isEmpty)
    }
}

extension SessionStoreTests {

    private func routedEvent(_ name: String, id: String = "s1") -> HookEvent {
        HookEvent(hookEventName: name, sessionId: id, cwd: "/tmp/project", message: nil,
                  hostPID: 4242, hostBundlePath: "/Applications/Claude.app",
                  hostBundleID: "com.anthropic.claudefordesktop", tty: "/dev/ttys001")
    }

    func testHookEventDecodesTheRouteFields() throws {
        let json = #"""
        {"hook_event_name":"SessionStart","session_id":"abc","cwd":"/tmp/p",
         "host_pid":4242,"host_bundle_path":"/Applications/Claude.app",
         "host_bundle_id":"com.anthropic.claudefordesktop","tty":"/dev/ttys001"}
        """#.data(using: .utf8)!
        let event = try JSONDecoder().decode(HookEvent.self, from: json)
        XCTAssertEqual(event.hostPID, 4242)
        XCTAssertEqual(event.hostBundlePath, "/Applications/Claude.app")
        XCTAssertEqual(event.hostBundleID, "com.anthropic.claudefordesktop")
        XCTAssertEqual(event.tty, "/dev/ttys001")
    }

    /// Events from an older hook binary have none of the new fields; decoding must
    /// still succeed rather than dropping the event.
    func testHookEventDecodesWithoutTheRouteFields() throws {
        let json = #"{"hook_event_name":"Stop","session_id":"abc","cwd":"/tmp/p"}"#.data(using: .utf8)!
        let event = try JSONDecoder().decode(HookEvent.self, from: json)
        XCTAssertNil(event.hostPID)
        XCTAssertNil(event.hostBundlePath)
        XCTAssertNil(event.hostBundleID)
        XCTAssertNil(event.tty)
    }

    func testStoreCarriesTheRouteFromTheEventToTheSession() {
        let store = SessionStore()
        store.apply(hook: routedEvent("SessionStart"), now: Date())
        let session = store.sessions["s1"]
        XCTAssertEqual(session?.hostPID, 4242)
        XCTAssertEqual(session?.hostBundlePath, "/Applications/Claude.app")
        XCTAssertEqual(session?.hostBundleID, "com.anthropic.claudefordesktop")
        XCTAssertEqual(session?.tty, "/dev/ttys001")
    }

    /// A transcript update must not wipe the route: the watcher knows nothing about
    /// the host, and losing the route would silently disable the jump mid-session.
    func testTranscriptActivityKeepsAnAlreadyKnownRoute() {
        let store = SessionStore()
        let start = Date()
        store.apply(hook: routedEvent("SessionStart"), now: start)
        store.apply(activity: TranscriptActivity(
            sessionId: "s1", projectPath: "/tmp/project",
            description: "правит файл", timestamp: start.addingTimeInterval(5)))
        XCTAssertEqual(store.sessions["s1"]?.hostPID, 4242)
        XCTAssertEqual(store.sessions["s1"]?.tty, "/dev/ttys001")
    }

    /// An event that carries no route (older hook) must not erase a route already
    /// recorded for that session.
    func testEventWithoutRouteDoesNotEraseAKnownRoute() {
        let store = SessionStore()
        let start = Date()
        store.apply(hook: routedEvent("SessionStart"), now: start)
        store.apply(hook: HookEvent(hookEventName: "Notification", sessionId: "s1",
                                    cwd: "/tmp/project", message: "permission"),
                    now: start.addingTimeInterval(1))
        XCTAssertEqual(store.sessions["s1"]?.hostPID, 4242)
        XCTAssertEqual(store.sessions["s1"]?.hostBundlePath, "/Applications/Claude.app")
    }

    /// A session that only ever appeared through the transcript watcher has no route.
    func testTranscriptOnlySessionHasNoRoute() {
        let store = SessionStore()
        store.apply(activity: TranscriptActivity(
            sessionId: "only-transcript", projectPath: "/tmp/p",
            description: "работает", timestamp: Date()))
        XCTAssertNil(store.sessions["only-transcript"]?.hostPID)
        XCTAssertNil(store.sessions["only-transcript"]?.tty)
    }
}
