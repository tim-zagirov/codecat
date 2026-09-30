import XCTest
@testable import CodeCatCore

/// `IslandFlow`: `PeekScheduler` and `IslandPresenter` driven together, the way the
/// island and the floating cat drive them. Each is tested alone elsewhere; what these
/// tests hold is the handshake — a scheduler that thinks a peek is still on screen
/// when the island has moved on never offers another one.
final class IslandPeekFlowTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_756_400_000)
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    /// A session list the tests change one status at a time.
    final class Fixture {
        let flow: IslandFlow
        private var statuses: [String: SessionStatus] = [:]
        private let t0: Date

        init(t0: Date, sessions: [String], settings: PeekSettings = .init()) {
            self.t0 = t0
            var statuses: [String: SessionStatus] = [:]
            for id in sessions { statuses[id] = .working }
            self.statuses = statuses
            flow = IslandFlow(hoverDelay: 0.3, settings: settings,
                              sessions: Self.sessions(statuses, t0: t0), now: t0)
        }

        var peeked: [String]? {
            if case .peek(let item) = flow.presentation { return item.sessionIDs }
            return nil
        }

        func set(_ id: String, _ status: SessionStatus, now: Date) {
            statuses[id] = status
            flow.sessionsChanged(Self.sessions(statuses, t0: t0), now: now)
        }

        func remove(_ id: String, now: Date) {
            statuses[id] = nil
            flow.sessionsChanged(Self.sessions(statuses, t0: t0), now: now)
        }

        static func sessions(_ statuses: [String: SessionStatus], t0: Date) -> [Session] {
            statuses.keys.sorted().map {
                Session(id: $0, projectPath: "/p/\($0)", status: statuses[$0]!,
                        activityDescription: "", startedAt: t0, lastActivity: t0)
            }
        }
    }

    /// (a) The list already shows everything: what happens while it is open does not
    /// come back as a peek after it closes — and the scheduler is not left believing
    /// a peek is on screen, so the next event still peeks.
    func testWhatHappensWhileTheListIsOpenIsDroppedAndPeeksResumeAfterItCloses() {
        let f = Fixture(t0: t0, sessions: ["a", "b", "c"])
        f.set("a", .waitingForYou(.permission), now: at(1))
        XCTAssertEqual(f.peeked, ["a"])

        f.flow.pointerEntered(now: at(1.5))
        f.flow.tick(now: at(1.81))
        XCTAssertEqual(f.flow.presentation, .expanded, "the dwell turned the peek into the list")

        f.set("b", .waitingForYou(.permission), now: at(3))
        XCTAssertEqual(f.flow.presentation, .expanded)

        f.flow.pointerLeft(now: at(4))
        f.flow.tick(now: at(4.16))
        XCTAssertEqual(f.flow.presentation, .compact, "b was seen in the open list")
        f.flow.tick(now: at(10))
        XCTAssertEqual(f.flow.presentation, .compact)

        f.set("c", .crashed, now: at(11))
        XCTAssertEqual(f.peeked, ["c"])
    }

    /// (b) Escape ends the peek; the next one waits out the 0.4 s gap.
    func testAfterEscapeTheNextPeekComesAfterTheGap() {
        let f = Fixture(t0: t0, sessions: ["a", "b"])
        f.set("a", .waitingForYou(.permission), now: at(1))
        f.set("b", .crashed, now: at(2.5))          // outside the merge window: queued
        XCTAssertEqual(f.peeked, ["a"])

        f.flow.escape(now: at(2.6))
        XCTAssertEqual(f.flow.presentation, .compact)
        f.flow.tick(now: at(2.9))
        XCTAssertEqual(f.flow.presentation, .compact, "within the gap")
        f.flow.tick(now: at(3.01))
        XCTAssertEqual(f.peeked, ["b"])
    }

    /// (c) A jump from the peek ends it like escape does.
    func testAJumpFromThePeekEndsItAndTheQueueCarriesOn() {
        let f = Fixture(t0: t0, sessions: ["a", "b"])
        f.set("a", .waitingForYou(.permission), now: at(1))
        f.set("b", .crashed, now: at(2.5))
        f.flow.jumped(now: at(2.6))
        XCTAssertEqual(f.flow.presentation, .compact)
        f.flow.tick(now: at(3.01))
        XCTAssertEqual(f.peeked, ["b"])
    }

    /// (d) A second session within the merge window replaces the peek on screen and
    /// restarts its hold; its end is the merged item's end.
    func testAMergeReplacesThePeekAndRestartsTheHold() {
        let f = Fixture(t0: t0, sessions: ["a", "b"])
        f.set("a", .waitingForYou(.permission), now: at(0))
        f.set("b", .waitingForYou(.question), now: at(0.8))
        XCTAssertEqual(f.peeked, ["a", "b"])
        guard case .peek(let merged) = f.flow.presentation else { return XCTFail("no peek") }
        XCTAssertEqual(merged.kind, .merged)

        f.flow.tick(now: at(3.5))
        XCTAssertEqual(f.flow.presentation, .peek(merged), "the hold restarted at 0.8")
        f.flow.tick(now: at(3.81))
        XCTAssertEqual(f.flow.presentation, .compact)

        f.set("a", .working, now: at(5))
        f.set("a", .crashed, now: at(6))
        XCTAssertEqual(f.peeked, ["a"], "the scheduler was not left holding the merged peek")
    }

    /// (e) Show on a merged peek opens the list and ends the peek.
    func testOpeningDuringAPeekEndsIt() {
        let f = Fixture(t0: t0, sessions: ["a", "b", "c"])
        f.set("a", .waitingForYou(.permission), now: at(0))
        f.set("b", .crashed, now: at(2))            // queued behind a
        f.flow.open(now: at(2.2))
        XCTAssertEqual(f.flow.presentation, .expanded)
        XCTAssertNil(f.flow.nextDeadline, "no hold and no queue left to fire on the list")

        f.flow.escape(now: at(3))
        XCTAssertEqual(f.flow.presentation, .compact, "b was in the list; the queue went with it")
        f.flow.tick(now: at(10))
        XCTAssertEqual(f.flow.presentation, .compact)

        f.set("c", .waitingForYou(.question), now: at(11))
        XCTAssertEqual(f.peeked, ["c"])
    }

    /// (f) A queued peek comes by itself once the gap is over: `nextDeadline` names
    /// the moment, and a tick there shows it.
    func testAQueuedPeekComesOnItsOwnAfterTheGap() {
        let f = Fixture(t0: t0, sessions: ["a", "b"])
        f.set("a", .waitingForYou(.permission), now: at(1))
        f.set("b", .crashed, now: at(2.5))
        f.flow.tick(now: at(4))                      // a's 3 s hold is over
        XCTAssertEqual(f.flow.presentation, .compact)
        guard let deadline = f.flow.nextDeadline else { return XCTFail("nothing to tick at") }
        XCTAssertEqual(deadline.timeIntervalSince(t0), 4.4, accuracy: 1e-6)
        f.flow.tick(now: deadline)
        XCTAssertEqual(f.peeked, ["b"], "a tick exactly at the deadline must not stall")
        f.flow.tick(now: at(4.41))
        XCTAssertEqual(f.peeked, ["b"])
    }

    /// (g) Handover contract 3: a peek whose session is gone ends, and the scheduler
    /// knows it.
    func testAPeekWhoseSessionIsGoneEnds() {
        let f = Fixture(t0: t0, sessions: ["a", "b"])
        f.set("a", .waitingForYou(.permission), now: at(1))
        f.remove("a", now: at(2))
        XCTAssertEqual(f.flow.presentation, .compact)
        f.set("b", .crashed, now: at(3))
        XCTAssertEqual(f.peeked, ["b"], "the scheduler was not left holding a's peek")
    }

    /// (h) Spec §6.2: nothing peeks on a locked screen; one summary on unlock.
    func testWhatHappensWhileLockedComesBackAsOneSummary() {
        let f = Fixture(t0: t0, sessions: ["a", "b"])
        f.flow.pointerEntered(now: at(0))
        f.flow.tick(now: at(0.31))
        XCTAssertEqual(f.flow.presentation, .expanded)
        f.flow.lock(now: at(1))
        XCTAssertEqual(f.flow.presentation, .compact, "the lock closes the open list, or the unlock would lose the summary")
        f.set("a", .done, now: at(2))
        f.set("b", .waitingForYou(.permission), now: at(3))
        XCTAssertEqual(f.flow.presentation, .compact, "nothing peeks on a locked screen")
        f.flow.unlock(now: at(5))
        guard case .peek(let item) = f.flow.presentation else { return XCTFail("no summary") }
        XCTAssertEqual(item.kind, .away(done: 1, waiting: 1, crashed: 0))
    }

    /// (i) A kind switched off in Settings › Alerts never peeks.
    func testASwitchedOffKindNeverPeeks() {
        let f = Fixture(t0: t0, sessions: ["a"], settings: PeekSettings(onWaiting: false))
        f.set("a", .waitingForYou(.permission), now: at(1))
        XCTAssertEqual(f.flow.presentation, .compact)
    }

    /// (j) Tim, 2026-09-30: a peek that appears under a resting cursor counts as
    /// hover — its hold pauses and it opens into the list after the hover delay.
    func testAPeekUnderARestingCursorOpensIntoTheList() {
        let f = Fixture(t0: t0, sessions: ["a"])
        f.flow.pointerEntered(now: at(0))
        f.flow.tick(now: at(0.31))
        XCTAssertEqual(f.flow.presentation, .expanded)
        f.flow.escape(now: at(1))                    // the cursor stays where it is
        f.set("a", .waitingForYou(.permission), now: at(2))
        XCTAssertEqual(f.peeked, ["a"])
        XCTAssertEqual(f.flow.peekHold, .paused(remaining: 3, total: 3))
        f.flow.tick(now: at(2.31))
        XCTAssertEqual(f.flow.presentation, .expanded)
    }
}
