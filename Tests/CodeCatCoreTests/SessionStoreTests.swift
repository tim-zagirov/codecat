import XCTest
@testable import CodeCatCore

final class SessionStoreTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_756_400_000)

    func hook(_ name: String, id: String = "s1", cwd: String? = "/proj",
              message: String? = nil) -> HookEvent {
        HookEvent(hookEventName: name, sessionId: id, cwd: cwd, message: message)
    }

    /// Сессия, в которой агент действительно работает: строка в транскрипте, а не
    /// просто открытая вкладка. `SessionStart` даёт `.idle` — см. `SessionStatus.idle`,
    /// поэтому тесты, которым нужна именно работающая сессия, заводят её так.
    @discardableResult
    func startWorking(_ store: SessionStore, id: String = "s1", cwd: String = "/proj",
                      at time: Date) -> SessionStore {
        store.apply(activity: TranscriptActivity(sessionId: id, projectPath: cwd,
                                                 description: "работает над задачей",
                                                 timestamp: time))
        return store
    }

    /// Жалоба, с которой всё началось: «ни один агент не запущен, а он показывает 1».
    /// `SessionStart` приходит, когда сессию открыли или возобновили, — работы в ней
    /// ещё нет, и в бейдже ей делать нечего.
    func testSessionStartCreatesIdleSessionThatIsNotCountedAnywhere() {
        let store = SessionStore()
        store.apply(hook: hook("SessionStart"), now: t0)
        XCTAssertEqual(store.ordered.count, 1, "сессию всё равно отслеживаем")
        XCTAssertEqual(store.ordered[0].status, .idle)
        XCTAssertEqual(store.ordered[0].projectPath, "/proj")
        XCTAssertEqual(store.aggregate, .sleeping)
        XCTAssertEqual(store.badgeCount, 0)
        XCTAssertFalse(store.anyWorking, "открытая вкладка не повод не давать маку заснуть")
    }

    /// `UserPromptSubmit` — точный момент начала работы, и он приходит по сокету
    /// сразу, не дожидаясь, пока FSEvents донесёт строку транскрипта.
    func testUserPromptSubmitStartsWorkImmediately() {
        let store = SessionStore()
        store.apply(hook: hook("SessionStart"), now: t0)
        XCTAssertEqual(store.aggregate, .sleeping)
        store.apply(hook: hook("UserPromptSubmit"), now: t0.addingTimeInterval(5))
        XCTAssertEqual(store.ordered[0].status, .working)
        XCTAssertEqual(store.aggregate, .working(1))
        XCTAssertTrue(store.anyWorking)
    }

    /// Полный круг одного турна: взялся → закончил → снова взялся.
    func testAPromptAfterAFinishedTurnMakesTheSessionWorkAgain() {
        let store = SessionStore()
        store.apply(hook: hook("UserPromptSubmit"), now: t0)
        store.apply(hook: hook("Stop"), now: t0.addingTimeInterval(60))
        XCTAssertEqual(store.aggregate, .done)
        store.apply(hook: hook("UserPromptSubmit"), now: t0.addingTimeInterval(120))
        XCTAssertEqual(store.ordered[0].status, .working)
        XCTAssertNil(store.ordered[0].finishedAt, "сессия снова в работе — не законченная")
    }

    /// И зеркальный случай: как только в сессии действительно началась работа
    /// (первая строка турна в транскрипте), она немедленно считается работающей.
    func testFirstTranscriptLineTurnsAnIdleSessionIntoAWorkingOne() {
        let store = SessionStore()
        store.apply(hook: hook("SessionStart"), now: t0)
        startWorking(store, at: t0.addingTimeInterval(30))
        XCTAssertEqual(store.ordered[0].status, .working)
        XCTAssertEqual(store.aggregate, .working(1))
        XCTAssertEqual(store.badgeCount, 1)
        XCTAssertTrue(store.anyWorking)
    }

    /// `SessionStart` с `source == "compact"` — это авто-компакция посреди работы,
    /// а не открытие сессии: сбросить работающую сессию в `.idle` значило бы гасить
    /// кота ровно в тот момент, когда агент занят.
    func testCompactSessionStartDoesNotResetAWorkingSessionToIdle() {
        let store = SessionStore()
        startWorking(store, at: t0)
        let compact = HookEvent(hookEventName: "SessionStart", sessionId: "s1", cwd: "/proj",
                                message: nil, source: "compact")
        store.apply(hook: compact, now: t0.addingTimeInterval(60))
        XCTAssertEqual(store.ordered[0].status, .working)
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

    func testSubagentActivityMarksDescriptionAsSubagentWork() {
        let store = SessionStore()
        let act = TranscriptActivity(sessionId: "s1", projectPath: "/proj",
                                     description: "running a command",
                                     timestamp: t0, isSubagent: true)
        store.apply(activity: act)
        XCTAssertEqual(store.ordered[0].activityDescription, "subagent running a command")
    }

    func testOrdinaryActivityDoesNotCarryTheSubagentMarker() {
        let store = SessionStore()
        let act = TranscriptActivity(sessionId: "s1", projectPath: "/proj",
                                     description: "running a command",
                                     timestamp: t0, isSubagent: false)
        store.apply(activity: act)
        XCTAssertEqual(store.ordered[0].activityDescription, "running a command")
    }

    /// Пин требования 3 из спеки: субагент, работающий внутри сессии, — это работа
    /// самой сессии. Если единственная активность, которую видел стор, пришла из
    /// транскрипта субагента, сессия всё равно должна агрегироваться, считаться в
    /// бейдже и удерживать мак от сна — иначе «работает 2» на экране разойдётся с
    /// тем, что мак реально не спит.
    func testSessionWithOnlySubagentActivityStillCountsAsWorking() {
        let store = SessionStore()
        let act = TranscriptActivity(sessionId: "s1", projectPath: "/proj",
                                     description: "running a command",
                                     timestamp: t0, isSubagent: true)
        store.apply(activity: act)
        XCTAssertEqual(store.aggregate, .working(1))
        XCTAssertEqual(store.badgeCount, 1)
        XCTAssertTrue(store.anyWorking)
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
        startWorking(store, id: "a", cwd: "/a", at: t0)
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
        startWorking(store, at: t0)
        // активность была давно, процессов claude нет → сессия упала
        store.reconcile(claudeProcessCount: 0, now: t0.addingTimeInterval(300))
        XCTAssertEqual(store.ordered[0].status, .crashed)
        XCTAssertEqual(store.aggregate, .problem)
    }

    func testReconcileKeepsFreshSessionsEvenWithZeroProcesses() {
        let store = SessionStore()
        startWorking(store, at: t0)
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
        startWorking(store, at: t0)
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
        startWorking(store, id: "a", cwd: "/a", at: t0)
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
        startWorking(store, at: t0)
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
        startWorking(store, at: t0)
        store.reconcile(claudeProcessCount: 1, now: t0.addingTimeInterval(3 * 60 * 60),
                        longStaleAfter: 3 * 60 * 60)
        XCTAssertEqual(store.ordered[0].status, .crashed)
    }

    func testReconcileKeepsFreshSessionWithProcessesAliveUnderLongStaleThreshold() {
        // The mirror case: a session that is genuinely still busy (or genuinely left
        // waiting) must not be killed out from under the user just because some other
        // `claude` process happens to be running elsewhere.
        let store = SessionStore()
        startWorking(store, at: t0)
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
        startWorking(store, at: t0)
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
        startWorking(store, at: t0)
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
        startWorking(store, at: t0)
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
        startWorking(store, at: t0)
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

// MARK: - «Есть ли сессии» — это не «чем занят кот»

extension SessionStoreTests {

    func testAnEmptyStoreHasNoSessions() {
        XCTAssertFalse(SessionStore().hasSessions)
    }

    /// Ключевой случай: сессия открыта, но простаивает. Кот при этом спит
    /// (`aggregate == .sleeping`, бейдж пуст) — а сессия есть, и настройка
    /// «прятать остров, когда сессий нет» не имеет права её не заметить.
    func testAnIdleSessionStillCountsAsASession() {
        let store = SessionStore()
        store.apply(hook: hook("SessionStart"), now: t0)
        XCTAssertEqual(store.aggregate, .sleeping, "коту показывать нечего")
        XCTAssertEqual(store.badgeCount, 0)
        XCTAssertTrue(store.hasSessions, "но сессия есть")
    }

    /// И законченная — тоже: она ещё висит в панели свой TTL, по ней можно
    /// кликнуть, значит прятать остров не за что.
    func testAFinishedSessionStillCountsAsASession() {
        let store = SessionStore()
        startWorking(store, at: t0)
        store.apply(hook: hook("Stop"), now: t0.addingTimeInterval(10))
        XCTAssertTrue(store.hasSessions)
    }

    /// А когда сессия ушла совсем — сессий нет.
    func testSessionEndLeavesNoSessions() {
        let store = SessionStore()
        store.apply(hook: hook("SessionStart"), now: t0)
        store.apply(hook: hook("SessionEnd"), now: t0.addingTimeInterval(10))
        XCTAssertFalse(store.hasSessions)
    }
}

// MARK: - Конец турна виден в транскрипте, а не только в хуке

extension SessionStoreTests {

    private func endOfTurn(id: String = "s1", at time: Date) -> TranscriptActivity {
        TranscriptActivity(sessionId: id, projectPath: "/proj", description: "закончил",
                           timestamp: time, endsTurn: true)
    }

    /// Ровно тот случай, что поймали на живой машине: сессия закончила турн, хук
    /// `Stop` до приложения не дошёл — и раньше она навсегда оставалась «работает»,
    /// продолжая давать единицу на бейдже при пустом столе.
    func testEndOfTurnInTheTranscriptFinishesTheSessionWithoutTheStopHook() {
        let store = SessionStore()
        startWorking(store, at: t0)
        XCTAssertEqual(store.aggregate, .working(1))
        store.apply(activity: endOfTurn(at: t0.addingTimeInterval(30)))
        XCTAssertEqual(store.ordered[0].status, .done)
        XCTAssertEqual(store.ordered[0].finishedAt, t0.addingTimeInterval(30),
                       "TTL показа отсчитывается от конца турна")
        XCTAssertEqual(store.aggregate, .done)
        XCTAssertEqual(store.badgeCount, 0)
        XCTAssertFalse(store.anyWorking, "мак больше незачем держать не спящим")
    }

    /// Субагент закончил свой турн — сессия продолжает работать: она разбирает его
    /// результат. Гасить её здесь значило бы усыплять кота посреди работы.
    func testSubagentEndOfTurnDoesNotFinishTheSession() {
        let store = SessionStore()
        startWorking(store, at: t0)
        let subagentDone = TranscriptActivity(
            sessionId: "s1", projectPath: "/proj", description: "закончил",
            timestamp: t0.addingTimeInterval(30), isSubagent: true, endsTurn: true)
        store.apply(activity: subagentDone)
        XCTAssertEqual(store.ordered[0].status, .working)
        XCTAssertEqual(store.badgeCount, 1)
    }

    /// Следующая реплика человека снова заводит работу — законченность не залипает.
    func testWorkResumesAfterAnEndOfTurnSeenInTheTranscript() {
        let store = SessionStore()
        startWorking(store, at: t0)
        store.apply(activity: endOfTurn(at: t0.addingTimeInterval(30)))
        startWorking(store, at: t0.addingTimeInterval(60))
        XCTAssertEqual(store.ordered[0].status, .working)
        XCTAssertNil(store.ordered[0].finishedAt)
        XCTAssertEqual(store.badgeCount, 1)
    }

    /// Законченная сессия истекает по обычному TTL — от конца турна.
    func testASessionFinishedByTheTranscriptExpiresOnTheUsualTTL() {
        let store = SessionStore()
        startWorking(store, at: t0)
        let end = t0.addingTimeInterval(30)
        store.apply(activity: endOfTurn(at: end))
        store.expireFinished(now: end.addingTimeInterval(599))
        XCTAssertEqual(store.ordered.count, 1)
        store.expireFinished(now: end.addingTimeInterval(601))
        XCTAssertTrue(store.ordered.isEmpty)
    }
}

// MARK: - Жива ли сессия: точный ответ по её собственному процессу

extension SessionStoreTests {

    private func agentEvent(_ name: String, id: String = "s1", agentPID: pid_t) -> HookEvent {
        HookEvent(hookEventName: name, sessionId: id, cwd: "/proj", message: nil,
                  agentPID: agentPID)
    }

    /// Тот самый призрак: сессию убили (kill, force quit — `SessionEnd` не дошёл),
    /// но рядом живы другие процессы `claude`, поэтому обнулить общий счётчик
    /// нечем. Раньше такая сессия висела в бейдже как работающая до четырёх часов.
    /// Со своим pid ответ известен сразу.
    func testDeadAgentProcessCrashesAWorkingSessionAtOnceEvenWithOtherClaudesAlive() {
        let store = SessionStore()
        store.apply(hook: agentEvent("SessionStart", agentPID: 4242), now: t0)
        startWorking(store, at: t0.addingTimeInterval(1))
        store.reconcile(claudeProcessCount: 3, now: t0.addingTimeInterval(30),
                        isAgentAlive: { _ in false })
        XCTAssertEqual(store.ordered[0].status, .crashed)
        XCTAssertEqual(store.ordered[0].finishedAt, t0.addingTimeInterval(30),
                       "TTL показа отсчитывается от момента, когда сессия оборвалась")
    }

    /// Сессию просто закрыли, ничего не запуская. Это не авария — показывать
    /// «оборвалась» не за что, строку надо убрать.
    func testDeadAgentProcessRemovesASessionThatWasNotWorking() {
        for (name, message) in [("SessionStart", nil), ("Notification", "permission"),
                                ("Stop", nil)] as [(String, String?)] {
            let store = SessionStore()
            store.apply(hook: HookEvent(hookEventName: name, sessionId: "s1", cwd: "/proj",
                                        message: message, agentPID: 4242), now: t0)
            store.reconcile(claudeProcessCount: 3, now: t0.addingTimeInterval(30),
                            isAgentAlive: { _ in false })
            XCTAssertTrue(store.ordered.isEmpty, "\(name): сессии больше нет")
            XCTAssertEqual(store.aggregate, .sleeping)
        }
    }

    /// Зеркало: молчание живой сессии не значит ничего. Один длинный вызов
    /// инструмента, открытая вкладка, к которой вернутся завтра — пока её процесс
    /// жив, убивать её нельзя, сколько бы ни прошло времени.
    func testLiveAgentProcessKeepsAQuietSessionEvenPastTheLongStaleThreshold() {
        let store = SessionStore()
        store.apply(hook: agentEvent("SessionStart", agentPID: 4242), now: t0)
        startWorking(store, at: t0.addingTimeInterval(1))
        store.reconcile(claudeProcessCount: 0, now: t0.addingTimeInterval(9 * 60 * 60),
                        isAgentAlive: { $0 == 4242 })
        XCTAssertEqual(store.ordered[0].status, .working)
    }

    /// У сессии, найденной только по транскрипту, своего pid нет — спрашивать не у
    /// кого, и для неё остаются прежние пороги тишины.
    func testSessionWithoutAgentPIDStillFallsBackToTheStalenessThresholds() {
        let store = SessionStore()
        startWorking(store, at: t0)
        store.reconcile(claudeProcessCount: 0, now: t0.addingTimeInterval(300),
                        isAgentAlive: { _ in XCTFail("спрашивать не про кого"); return true })
        XCTAssertEqual(store.ordered[0].status, .crashed)
    }

    /// Событие от старой версии хука (без `agent_pid`) не должно стирать уже
    /// известный pid: иначе сессия теряла бы единственный точный признак жизни
    /// ровно в тот момент, когда о ней пришла новость.
    func testAnEventWithoutAgentPIDDoesNotClearAKnownOne() {
        let store = SessionStore()
        store.apply(hook: agentEvent("SessionStart", agentPID: 4242), now: t0)
        store.apply(hook: hook("Stop"), now: t0.addingTimeInterval(10))
        XCTAssertEqual(store.sessions["s1"]?.agentPID, 4242)
    }

    func testHookEventDecodesTheAgentPID() throws {
        let json = #"""
        {"hook_event_name":"Stop","session_id":"abc","cwd":"/tmp/p","agent_pid":4242}
        """#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(HookEvent.self, from: json).agentPID, 4242)
    }

    // MARK: - Сколько живёт открытая, но неработающая сессия

    /// Без своего pid судьбу открытой сессии определяет тот же TTL, что и у
    /// законченной: держать её строку вечно не за чем.
    func testIdleSessionWithoutAgentPIDExpiresOnTheUsualTTL() {
        let store = SessionStore()
        store.apply(hook: hook("SessionStart"), now: t0)
        store.expireFinished(now: t0.addingTimeInterval(599))
        XCTAssertEqual(store.ordered.count, 1)
        store.expireFinished(now: t0.addingTimeInterval(601))
        XCTAssertTrue(store.ordered.isEmpty)
    }

    /// А если её процесс можно спросить — строка остаётся, пока сессия жива: по ней
    /// можно кликнуть и вернуться в свою вкладку. В бейдж она при этом не попадает.
    func testIdleSessionWithAKnownAgentSurvivesTheTTL() {
        let store = SessionStore()
        store.apply(hook: agentEvent("SessionStart", agentPID: 4242), now: t0)
        store.expireFinished(now: t0.addingTimeInterval(6000))
        XCTAssertEqual(store.ordered.count, 1)
        XCTAssertEqual(store.badgeCount, 0)
        XCTAssertEqual(store.aggregate, .sleeping)
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
         "host_bundle_id":"com.anthropic.claudefordesktop","host_tty":"/dev/ttys001"}
        """#.data(using: .utf8)!
        let event = try JSONDecoder().decode(HookEvent.self, from: json)
        XCTAssertEqual(event.hostPID, 4242)
        XCTAssertEqual(event.hostBundlePath, "/Applications/Claude.app")
        XCTAssertEqual(event.hostBundleID, "com.anthropic.claudefordesktop")
        XCTAssertEqual(event.tty, "/dev/ttys001")
    }

    /// The real payload captured from a live `claude -p` run (see
    /// route-cache-report.md): `SessionStart` carries `source`, observed values
    /// `"startup"` and `"resume"`.
    func testHookEventDecodesTheSourceField() throws {
        let json = #"""
        {"hook_event_name":"SessionStart","session_id":"abc","cwd":"/tmp/p","source":"resume"}
        """#.data(using: .utf8)!
        let event = try JSONDecoder().decode(HookEvent.self, from: json)
        XCTAssertEqual(event.source, "resume")
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

    /// Empty strings are what a partial read produces (an unreadable Info.plist, a
    /// process with no controlling terminal reported as ""). They carry no route and
    /// must not clear one that is already known — the absent case is covered above,
    /// this is the empty-string one.
    func testEventWithEmptyRouteStringsDoesNotEraseAKnownRoute() {
        let store = SessionStore()
        let start = Date()
        store.apply(hook: routedEvent("SessionStart"), now: start)
        store.apply(hook: HookEvent(hookEventName: "Notification", sessionId: "s1",
                                    cwd: "/tmp/project", message: "permission",
                                    hostPID: nil, hostBundlePath: "", hostBundleID: "", tty: ""),
                    now: start.addingTimeInterval(1))
        XCTAssertEqual(store.sessions["s1"]?.hostPID, 4242)
        XCTAssertEqual(store.sessions["s1"]?.hostBundlePath, "/Applications/Claude.app")
        XCTAssertEqual(store.sessions["s1"]?.hostBundleID, "com.anthropic.claudefordesktop")
        XCTAssertEqual(store.sessions["s1"]?.tty, "/dev/ttys001")
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

    // MARK: - badgeCount

    /// Regression test for the reported bug: two agents genuinely working, but the
    /// badge said 5. Root cause was `OverlayPanel` passing `ordered.count` — every
    /// tracked session, including three `.done` ones still lingering inside
    /// `expireFinished`'s TTL — while the badge's colour came from `aggregate`, which
    /// only counts the two `.working` sessions. `badgeCount` must track `aggregate`,
    /// so the number and the colour always describe the same population.
    func testBadgeCountRegressionTwoWorkingThreeDoneReportsTwoNotFive() {
        let store = SessionStore()
        startWorking(store, id: "w1", cwd: "/w1", at: t0)
        startWorking(store, id: "w2", cwd: "/w2", at: t0)
        for id in ["d1", "d2", "d3"] {
            store.apply(hook: hook("SessionStart", id: id, cwd: "/\(id)"), now: t0)
            store.apply(hook: hook("Stop", id: id), now: t0.addingTimeInterval(1))
        }
        XCTAssertEqual(store.ordered.count, 5)
        XCTAssertEqual(store.aggregate, .working(2))
        XCTAssertEqual(store.badgeCount, 2)
    }

    func testBadgeCountWaitingOutranksWorking() {
        let store = SessionStore()
        store.apply(hook: hook("SessionStart", id: "n", cwd: "/n"), now: t0)
        store.apply(hook: hook("Notification", id: "n", message: "нужно разрешение"),
                    now: t0.addingTimeInterval(10))
        startWorking(store, id: "w1", cwd: "/w1", at: t0)
        startWorking(store, id: "w2", cwd: "/w2", at: t0)
        XCTAssertEqual(store.aggregate, .waiting(1))
        XCTAssertEqual(store.badgeCount, 1)
    }

    func testBadgeCountReportsAllWaitingSessionsNotJustOne() {
        let store = SessionStore()
        for id in ["n1", "n2", "n3"] {
            store.apply(hook: hook("SessionStart", id: id, cwd: "/\(id)"), now: t0)
            store.apply(hook: hook("Notification", id: id, message: "нужно разрешение"),
                        now: t0.addingTimeInterval(10))
        }
        startWorking(store, id: "w1", cwd: "/w1", at: t0)
        startWorking(store, id: "w2", cwd: "/w2", at: t0)
        XCTAssertEqual(store.aggregate, .waiting(3))
        XCTAssertEqual(store.badgeCount, 3)
    }

    /// Оборвавшаяся сессия не работает — числа у неё нет, только поза тревоги.
    func testProblemShowsThePoseWithoutANumber() {
        let store = SessionStore()
        // c1 works, then goes stale with no claude processes alive -> crashed.
        startWorking(store, id: "c1", cwd: "/c1", at: t0)
        store.reconcile(claudeProcessCount: 0, now: t0.addingTimeInterval(300))
        // d1 finishes normally -> done.
        store.apply(hook: hook("SessionStart", id: "d1", cwd: "/d1"), now: t0)
        store.apply(hook: hook("Stop", id: "d1"), now: t0.addingTimeInterval(10))
        XCTAssertEqual(store.aggregate, .problem)
        XCTAssertEqual(store.badgeCount, 0)
    }

    /// Жалоба, ради которой правило и переписано: «ничего не запущено, а на бейдже
    /// 2» — это были две сессии, закончившие турн в последние десять минут. Кот
    /// показывает, что работа сделана, позой; число же значит ровно «столько агентов
    /// сейчас заняты», и здесь оно ноль.
    func testFinishedSessionsShowThePoseWithoutANumber() {
        let store = SessionStore()
        for id in ["d1", "d2"] {
            store.apply(hook: hook("SessionStart", id: id, cwd: "/\(id)"), now: t0)
            store.apply(hook: hook("Stop", id: id), now: t0.addingTimeInterval(10))
        }
        XCTAssertEqual(store.aggregate, .done)
        XCTAssertEqual(store.badgeCount, 0)
    }

    /// И зеркало: как только в одной из них снова начинается работа — ровно единица,
    /// а не «две законченные плюс одна».
    func testOneWorkingSessionAmongFinishedOnesBadgesExactlyOne() {
        let store = SessionStore()
        for id in ["d1", "d2"] {
            store.apply(hook: hook("SessionStart", id: id, cwd: "/\(id)"), now: t0)
            store.apply(hook: hook("Stop", id: id), now: t0.addingTimeInterval(10))
        }
        store.apply(hook: hook("UserPromptSubmit", id: "d1"), now: t0.addingTimeInterval(20))
        XCTAssertEqual(store.aggregate, .working(1))
        XCTAssertEqual(store.badgeCount, 1)
    }

    func testBadgeCountIsZeroForEmptySleepingStore() {
        let store = SessionStore()
        XCTAssertEqual(store.aggregate, .sleeping)
        XCTAssertEqual(store.badgeCount, 0)
    }

    /// Инвариант числа на бейдже: оно никогда не больше того, что стор реально
    /// держит, и оно ненулевое ровно тогда, когда есть чем быть занятым — то есть в
    /// состояниях «работает» и «ждёт тебя», и только в них.
    func testBadgeCountInvariantNeverExceedsOrderedCountAndIsNonZeroOnlyForWorkOrWaiting() {
        func assertInvariant(_ store: SessionStore, file: StaticString = #filePath,
                             line: UInt = #line) {
            XCTAssertLessThanOrEqual(store.badgeCount, store.ordered.count, file: file, line: line)
            let inFlight: Bool
            switch store.aggregate {
            case .working, .waiting: inFlight = true
            case .done, .problem, .sleeping: inFlight = false
            }
            XCTAssertEqual(store.badgeCount > 0, inFlight, file: file, line: line)
        }

        let empty = SessionStore()
        assertInvariant(empty)

        let working = SessionStore()
        startWorking(working, id: "w1", cwd: "/w1", at: t0)
        startWorking(working, id: "w2", cwd: "/w2", at: t0)
        assertInvariant(working)

        let waiting = SessionStore()
        waiting.apply(hook: hook("SessionStart", id: "n1", cwd: "/n1"), now: t0)
        waiting.apply(hook: hook("Notification", id: "n1", message: "нужно разрешение"),
                     now: t0.addingTimeInterval(10))
        startWorking(waiting, id: "w1", cwd: "/w1", at: t0)
        assertInvariant(waiting)

        let done = SessionStore()
        done.apply(hook: hook("SessionStart", id: "d1", cwd: "/d1"), now: t0)
        done.apply(hook: hook("Stop", id: "d1"), now: t0.addingTimeInterval(10))
        assertInvariant(done)

        let problem = SessionStore()
        startWorking(problem, id: "c1", cwd: "/c1", at: t0)
        problem.reconcile(claudeProcessCount: 0, now: t0.addingTimeInterval(300))
        assertInvariant(problem)

        let mixedWorkingAndDone = SessionStore()
        startWorking(mixedWorkingAndDone, id: "w1", cwd: "/w1", at: t0)
        mixedWorkingAndDone.apply(hook: hook("SessionStart", id: "d1", cwd: "/d1"), now: t0)
        mixedWorkingAndDone.apply(hook: hook("Stop", id: "d1"), now: t0.addingTimeInterval(10))
        assertInvariant(mixedWorkingAndDone)
    }
}

extension SessionStoreTests {

    // MARK: - Route cache integration
    //
    // `SessionRouteCache(url: nil)` is in-memory only (see its doc comment): these
    // tests seed/read it directly and never touch disk, keeping `SessionStore`
    // testable on fixed values the same way the rest of this file is.

    /// The whole point of the cache: a session the transcript watcher discovers
    /// after a CodeCat restart (no hook data at all) must regain its route *and*
    /// its real `startedAt` from a cache entry left by the hook before the restart.
    func testWatcherDiscoveredSessionGainsRouteAndStartedAtFromCache() {
        let cache = SessionRouteCache()
        let realStart = t0.addingTimeInterval(-3600) // сессия шла час до перезапуска CodeCat
        cache.record(sessionId: "s1", hostPID: 4242, hostBundlePath: "/Applications/Claude.app",
                    hostBundleID: "com.anthropic.claudefordesktop", tty: "/dev/ttys001",
                    startedAt: realStart, now: realStart)

        let store = SessionStore(routeCache: cache)
        store.apply(activity: TranscriptActivity(
            sessionId: "s1", projectPath: "/proj", description: "правит файл", timestamp: t0))

        let session = store.sessions["s1"]
        XCTAssertEqual(session?.hostPID, 4242)
        XCTAssertEqual(session?.hostBundlePath, "/Applications/Claude.app")
        XCTAssertEqual(session?.hostBundleID, "com.anthropic.claudefordesktop")
        XCTAssertEqual(session?.tty, "/dev/ttys001")
        XCTAssertEqual(session?.startedAt, realStart, "должен унаследовать реальное время старта, а не момент обнаружения вотчером")
    }

    /// Same substitution, but the first sighting comes through the hook (e.g. the
    /// hook fires `SessionStart` for a session CodeCat already has a cached route
    /// for — a stale cache entry from before this exact restart).
    func testHookDiscoveredSessionGainsMissingRouteFieldsFromCache() {
        let cache = SessionRouteCache()
        let realStart = t0.addingTimeInterval(-120)
        cache.record(sessionId: "s1", hostPID: 4242, hostBundlePath: "/Applications/Claude.app",
                    hostBundleID: "com.anthropic.claudefordesktop", tty: "/dev/ttys001",
                    startedAt: realStart, now: realStart)

        let store = SessionStore(routeCache: cache)
        // A hook event carrying no route fields at all (older hook binary) — the
        // cache is the only source of the route for a session this store has
        // never seen before.
        store.apply(hook: HookEvent(hookEventName: "Notification", sessionId: "s1",
                                    cwd: "/proj", message: "нужно разрешение"), now: t0)

        let session = store.sessions["s1"]
        XCTAssertEqual(session?.hostPID, 4242)
        XCTAssertEqual(session?.tty, "/dev/ttys001")
        XCTAssertEqual(session?.startedAt, realStart)
    }

    /// Route fields the hook brings must reach the cache (so a *later* restart can
    /// restore them) — and a subsequent event that carries none of them must not
    /// clobber what the cache already has, mirroring the never-clobber rule
    /// `SessionStore` already enforces on the in-memory `Session`.
    func testHookFieldsAreRecordedIntoCacheAndNotClobberedByALaterEventWithoutThem() {
        let cache = SessionRouteCache()
        let store = SessionStore(routeCache: cache)
        store.apply(hook: routedEvent("SessionStart"), now: t0)
        XCTAssertEqual(cache.route(for: "s1")?.hostPID, 4242)
        XCTAssertEqual(cache.route(for: "s1")?.startedAt, t0)

        // A later event for the same session with no route fields at all.
        store.apply(hook: HookEvent(hookEventName: "Notification", sessionId: "s1",
                                    cwd: "/tmp/project", message: "permission"),
                    now: t0.addingTimeInterval(5))
        XCTAssertEqual(cache.route(for: "s1")?.hostPID, 4242,
                       "поле, уже известное кэшу, не должно затираться событием без маршрута")
        XCTAssertEqual(cache.route(for: "s1")?.hostBundlePath, "/Applications/Claude.app")
    }

    /// `SessionEnd` must drop the cache entry — the session is over, nothing to
    /// remember for a future restart.
    func testSessionEndRemovesTheCacheEntry() {
        let cache = SessionRouteCache()
        let store = SessionStore(routeCache: cache)
        store.apply(hook: routedEvent("SessionStart"), now: t0)
        XCTAssertNotNil(cache.route(for: "s1"))
        store.apply(hook: hook("SessionEnd"), now: t0.addingTimeInterval(10))
        XCTAssertNil(cache.route(for: "s1"))
    }

    /// Pins the whole design: a cache full of routes, on its own, must never
    /// produce a session. Sessions only ever come from live activity — a hook
    /// event or a transcript line — never from what the cache happens to hold.
    func testPopulatedCacheWithNoLiveActivityProducesNoSessions() {
        let cache = SessionRouteCache()
        cache.record(sessionId: "ghost", hostPID: 9999, hostBundlePath: "/Applications/Claude.app",
                    hostBundleID: "com.anthropic.claudefordesktop", tty: "/dev/ttys002",
                    startedAt: t0.addingTimeInterval(-1000), now: t0.addingTimeInterval(-1000))
        let store = SessionStore(routeCache: cache)
        XCTAssertTrue(store.ordered.isEmpty)
        XCTAssertEqual(store.aggregate, .sleeping)
    }

    /// A session id the cache has never heard of must not blow up substitution —
    /// it simply gets no route, same as today without a cache at all.
    func testUnknownSessionIdInCacheLeavesSessionWithoutARoute() {
        let cache = SessionRouteCache()
        cache.record(sessionId: "some-other-session", hostPID: 1, hostBundlePath: "/a",
                    hostBundleID: "a", tty: "/dev/t1", startedAt: t0, now: t0)
        let store = SessionStore(routeCache: cache)
        store.apply(activity: TranscriptActivity(
            sessionId: "s1", projectPath: "/proj", description: "думает", timestamp: t0))
        XCTAssertNil(store.sessions["s1"]?.hostPID)
    }

    // MARK: - Review item 1: a genuine SessionStart resets a stale cached startedAt
    //
    // Root cause: a session that ends *without* `SessionEnd` (terminal closed,
    // SIGKILL) leaves its cache entry behind — `merged` freezes `startedAt` forever.
    // If the user later runs `claude --resume` on that id, the empirically-observed
    // real payload is `{"hook_event_name":"SessionStart", ..., "source":"resume"}`
    // (captured from a live `claude -p` / `claude --resume` run against a listener
    // bound to the hook socket — see route-cache-report.md). Without this fix,
    // `newSession` took `startedAt` straight from the stale cache entry, so the row
    // read "длится N ч" for a session that had just started.

    /// The bug, pinned: a stale cache entry plus a real `SessionStart(source: resume)`
    /// must produce a session whose `startedAt` is the event's own time, not the
    /// cache's frozen one.
    func testSessionStartWithSourceResumeResetsAStaleCachedStartedAt() {
        let cache = SessionRouteCache()
        let staleStart = t0.addingTimeInterval(-72 * 60 * 60) // «застряло» 72 часа назад
        cache.record(sessionId: "s1", hostPID: 4242, hostBundlePath: "/Applications/Claude.app",
                    hostBundleID: "com.anthropic.claudefordesktop", tty: "/dev/ttys001",
                    startedAt: staleStart, now: staleStart)

        let store = SessionStore(routeCache: cache)
        store.apply(hook: HookEvent(hookEventName: "SessionStart", sessionId: "s1",
                                    cwd: "/proj", message: nil, hostPID: 4242,
                                    hostBundlePath: "/Applications/Claude.app",
                                    hostBundleID: "com.anthropic.claudefordesktop",
                                    tty: "/dev/ttys001", source: "resume"),
                    now: t0)

        XCTAssertEqual(store.sessions["s1"]?.startedAt, t0,
                       "resume — это настоящий новый запуск, длительность должна отсчитываться заново")
    }

    /// A missing/unknown `source` must reset too — that is the safe default, since
    /// `SessionStart` never fires merely because CodeCat restarted (only a real
    /// Claude Code lifecycle event sends it at all).
    func testSessionStartWithMissingSourceAlsoResetsAStaleCachedStartedAt() {
        let cache = SessionRouteCache()
        let staleStart = t0.addingTimeInterval(-72 * 60 * 60)
        cache.record(sessionId: "s1", hostPID: 4242, hostBundlePath: "/Applications/Claude.app",
                    hostBundleID: "com.anthropic.claudefordesktop", tty: "/dev/ttys001",
                    startedAt: staleStart, now: staleStart)

        let store = SessionStore(routeCache: cache)
        store.apply(hook: routedEvent("SessionStart"), now: t0) // no `source` at all
        XCTAssertEqual(store.sessions["s1"]?.startedAt, t0)
    }

    /// The mirror case that must NOT reset: `SessionStart` also fires mid-session
    /// after auto-compaction, with `source == "compact"`. Resetting there would
    /// break the duration of a session that never stopped.
    func testSessionStartWithSourceCompactPreservesTheCachedStartedAt() {
        let cache = SessionRouteCache()
        let realStart = t0.addingTimeInterval(-3600)
        cache.record(sessionId: "s1", hostPID: 4242, hostBundlePath: "/Applications/Claude.app",
                    hostBundleID: "com.anthropic.claudefordesktop", tty: "/dev/ttys001",
                    startedAt: realStart, now: realStart)

        let store = SessionStore(routeCache: cache)
        store.apply(hook: HookEvent(hookEventName: "SessionStart", sessionId: "s1",
                                    cwd: "/proj", message: nil, hostPID: 4242,
                                    hostBundlePath: "/Applications/Claude.app",
                                    hostBundleID: "com.anthropic.claudefordesktop",
                                    tty: "/dev/ttys001", source: "compact"),
                    now: t0)

        XCTAssertEqual(store.sessions["s1"]?.startedAt, realStart,
                       "автокомпакция не должна сбрасывать время начала ещё идущей сессии")
    }

    /// The core feature this cache exists for must be unaffected by the fix above:
    /// a CodeCat restart fires no `SessionStart` at all, so a session the transcript
    /// watcher rediscovers keeps the cache's `startedAt` exactly as before.
    /// (Mirrors `testWatcherDiscoveredSessionGainsRouteAndStartedAtFromCache`, stated
    /// explicitly here as the "preservation" half of the review's requested pin.)
    func testSessionReappearingWithNoSessionStartAtAllPreservesTheCachedStartedAt() {
        let cache = SessionRouteCache()
        let realStart = t0.addingTimeInterval(-3600)
        cache.record(sessionId: "s1", hostPID: 4242, hostBundlePath: "/Applications/Claude.app",
                    hostBundleID: "com.anthropic.claudefordesktop", tty: "/dev/ttys001",
                    startedAt: realStart, now: realStart)

        let store = SessionStore(routeCache: cache)
        store.apply(activity: TranscriptActivity(
            sessionId: "s1", projectPath: "/proj", description: "правит файл", timestamp: t0))

        XCTAssertEqual(store.sessions["s1"]?.startedAt, realStart,
                       "без SessionStart перезапуск CodeCat не должен сбрасывать время начала")
    }

    /// The reset must also reach the persisted cache entry itself — otherwise a
    /// *second* silent crash-without-SessionEnd followed by another resume within
    /// the 7-day window would restore the stale value all over again.
    func testResetStartedAtIsPersistedBackIntoTheCache() {
        let cache = SessionRouteCache()
        let staleStart = t0.addingTimeInterval(-72 * 60 * 60)
        cache.record(sessionId: "s1", hostPID: 4242, hostBundlePath: "/Applications/Claude.app",
                    hostBundleID: "com.anthropic.claudefordesktop", tty: "/dev/ttys001",
                    startedAt: staleStart, now: staleStart)

        let store = SessionStore(routeCache: cache)
        store.apply(hook: HookEvent(hookEventName: "SessionStart", sessionId: "s1",
                                    cwd: "/proj", message: nil, hostPID: 4242,
                                    hostBundlePath: "/Applications/Claude.app",
                                    hostBundleID: "com.anthropic.claudefordesktop",
                                    tty: "/dev/ttys001", source: "resume"),
                    now: t0)

        XCTAssertEqual(cache.route(for: "s1")?.startedAt, t0,
                       "сброс должен попасть и в сам кэш, иначе следующий сбой без SessionEnd снова унаследует старое время")
    }

    // MARK: - Fix wave 2

    /// Item 1: `upsert`'s `sessions[event.sessionId] ?? newSession(...)` only runs
    /// `newSession` — and therefore only applies `resetStartedAt` — when the id is
    /// absent from `sessions`. A session CodeCat still remembers (lingering `.done`
    /// inside `expireFinished`'s TTL) is very much still present, so a real
    /// `SessionStart(source: "resume")` for it must still reset `startedAt` to the
    /// event's own time — that is exactly the reachable "длится 72 ч" case the
    /// previous wave's fix silently failed to cover.
    func testSessionStartResumeResetsStartedAtEvenWhenSessionStillLingersInStore() {
        let store = SessionStore()
        store.apply(hook: routedEvent("SessionStart"), now: t0)
        store.apply(hook: hook("Stop"), now: t0.addingTimeInterval(10)) // done, but still in `sessions`
        XCTAssertNotNil(store.sessions["s1"], "сессия должна ещё жить в сторе — TTL не истёк")

        let muchLater = t0.addingTimeInterval(72 * 60 * 60)
        store.apply(hook: HookEvent(hookEventName: "SessionStart", sessionId: "s1",
                                    cwd: "/proj", message: nil, hostPID: 4242,
                                    hostBundlePath: "/Applications/Claude.app",
                                    hostBundleID: "com.anthropic.claudefordesktop",
                                    tty: "/dev/ttys001", source: "resume"),
                    now: muchLater)

        XCTAssertEqual(store.sessions["s1"]?.startedAt, muchLater,
                       "resume сессии, всё ещё лежащей в сторе, должен сбросить время начала")
    }

    /// The mirror case: a session reappearing with no `SessionStart` at all (a plain
    /// CodeCat restart while it kept running) must keep the cached `startedAt` even
    /// when it goes through the hook path rather than the transcript watcher.
    func testEventWithoutSessionStartNeverResetsStartedAtEvenWhenSessionStillLingersInStore() {
        let store = SessionStore()
        store.apply(hook: routedEvent("SessionStart"), now: t0)
        let originalStart = store.sessions["s1"]?.startedAt
        store.apply(hook: hook("Notification", message: "нужно разрешение"),
                    now: t0.addingTimeInterval(5))
        XCTAssertEqual(store.sessions["s1"]?.startedAt, originalStart,
                       "не-SessionStart событие не должно трогать startedAt")
    }

    /// Item 2: the host triple must be replaced as a unit in `upsert`, not merged
    /// field by field — otherwise an event carrying a fresh pid and path but no
    /// bundle id (the hook's separate `Bundle(path:)?.bundleIdentifier` lookup can
    /// independently return nil) leaves the *previous* host's bundle id in place,
    /// pairing it with the *new* host's pid/path — a route that names two different
    /// hosts at once and gets scripted wrong by `SessionRouter.route`.
    func testEventWithFreshPidAndPathButNoBundleIdClearsThePreviousBundleId() {
        let store = SessionStore()
        store.apply(hook: routedEvent("SessionStart"), now: t0)
        XCTAssertEqual(store.sessions["s1"]?.hostBundleID, "com.anthropic.claudefordesktop")

        store.apply(hook: HookEvent(hookEventName: "Notification", sessionId: "s1",
                                    cwd: "/proj", message: "permission",
                                    hostPID: 4343, hostBundlePath: "/Applications/Utilities/Terminal.app",
                                    hostBundleID: nil, tty: nil),
                    now: t0.addingTimeInterval(5))

        let session = store.sessions["s1"]
        XCTAssertEqual(session?.hostPID, 4343)
        XCTAssertEqual(session?.hostBundlePath, "/Applications/Utilities/Terminal.app")
        XCTAssertNil(session?.hostBundleID,
                     "новый хост без bundle id не должен унаследовать bundle id старого хоста")
    }

    /// Item 3: when `resetStartedAt` is true, `record` must be called even when the
    /// event carries no route fields at all (non-interactive `claude -p` under tmux,
    /// ssh or CI — no `.app` ancestor, no tty). Otherwise the in-memory session gets
    /// the reset `startedAt` but the persisted cache entry keeps its stale
    /// `startedAt`/`updatedAt`, and a CodeCat restart within seven days reintroduces
    /// the stale duration.
    func testResetStartedAtReachesTheCacheEvenWithNoRouteFieldsAtAll() {
        let cache = SessionRouteCache()
        let staleStart = t0.addingTimeInterval(-72 * 60 * 60)
        cache.record(sessionId: "s1", hostPID: 4242, hostBundlePath: "/Applications/Claude.app",
                    hostBundleID: "com.anthropic.claudefordesktop", tty: "/dev/ttys001",
                    startedAt: staleStart, now: staleStart)

        let store = SessionStore(routeCache: cache)
        // No host/tty fields at all — non-interactive claude -p under tmux/ssh/CI.
        store.apply(hook: HookEvent(hookEventName: "SessionStart", sessionId: "s1",
                                    cwd: "/proj", message: nil, source: "resume"),
                    now: t0)

        XCTAssertEqual(store.sessions["s1"]?.startedAt, t0)
        XCTAssertEqual(cache.route(for: "s1")?.startedAt, t0,
                       "сброс должен попасть в кэш, даже если событие не несёт полей маршрута")
    }
}
