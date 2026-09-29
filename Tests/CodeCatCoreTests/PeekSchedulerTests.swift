import XCTest
@testable import CodeCatCore

final class PeekSchedulerTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_756_400_000)

    func s(_ id: String, _ status: SessionStatus) -> Session {
        Session(id: id, projectPath: "/p/\(id)", status: status, activityDescription: "",
                startedAt: t0, lastActivity: t0)
    }

    /// Seeds the scheduler with sessions it has already seen, so the next change is
    /// a transition and not a first sighting.
    func seeded(_ sessions: [Session], settings: PeekSettings = .init()) -> PeekScheduler {
        let p = PeekScheduler(settings: settings)
        p.sessionsChanged(sessions, now: t0)
        return p
    }

    func testFirstSightingNeverPeeks() {
        let p = PeekScheduler()
        p.sessionsChanged([s("a", .waitingForYou(.permission))], now: t0)
        XCTAssertNil(p.next(now: t0.addingTimeInterval(1)))
    }

    func testEnteringEachStatePeeksWithItsHold() {
        let cases: [(SessionStatus, SessionStatus, PeekItem.Kind, TimeInterval)] = [
            (.working, .waitingForYou(.permission), .waiting, 3),
            (.working, .waitingForYou(.question), .waiting, 3),
            (.working, .crashed, .crashed, 3),
            (.working, .done, .done, 1.5),
            (.waitingForYou(.idle), .done, .done, 1.5),
        ]
        for (from, to, kind, hold) in cases {
            let p = seeded([s("a", from)])
            p.sessionsChanged([s("a", to)], now: t0.addingTimeInterval(1))
            let item = p.next(now: t0.addingTimeInterval(1))
            XCTAssertEqual(item?.kind, kind, "\(from) → \(to)")
            XCTAssertEqual(item?.sessionIDs, ["a"])
            XCTAssertEqual(item?.hold, hold)
        }
    }

    func testNudgesGuessesAndRoutineChangesNeverPeek() {
        for (from, to) in [(SessionStatus.done, SessionStatus.waitingForYou(.input)),
                           (.working, .waitingForYou(.idle)),
                           (.idle, .working),
                           (.idle, .done)] {
            let p = seeded([s("a", from)])
            p.sessionsChanged([s("a", to)], now: t0.addingTimeInterval(1))
            XCTAssertNil(p.next(now: t0.addingTimeInterval(1)), "\(from) → \(to)")
        }
    }

    func testStayingInAStateDoesNotPeekTwice() {
        let p = seeded([s("a", .working)])
        p.sessionsChanged([s("a", .waitingForYou(.permission))], now: t0.addingTimeInterval(1))
        XCTAssertNotNil(p.next(now: t0.addingTimeInterval(1)))
        p.peekEnded(now: t0.addingTimeInterval(4))
        p.sessionsChanged([s("a", .waitingForYou(.permission))], now: t0.addingTimeInterval(5))
        XCTAssertNil(p.next(now: t0.addingTimeInterval(6)))
    }

    func testSwitchesDropTheirKind() {
        let p = seeded([s("a", .working), s("b", .working), s("c", .working)],
                       settings: PeekSettings(onWaiting: false, onCrash: false, onDone: false))
        p.sessionsChanged([s("a", .waitingForYou(.permission)), s("b", .crashed), s("c", .done)],
                          now: t0.addingTimeInterval(1))
        XCTAssertNil(p.next(now: t0.addingTimeInterval(1)))
    }

    /// Two agents asking within a second are one peek, not two in a row.
    func testAttentionWithinTheWindowMergesIntoTheShowingPeek() {
        let p = seeded([s("a", .working), s("b", .working)])
        p.sessionsChanged([s("a", .waitingForYou(.permission)), s("b", .working)], now: t0.addingTimeInterval(1))
        XCTAssertEqual(p.next(now: t0.addingTimeInterval(1))?.kind, .waiting)
        let replacement = p.sessionsChanged([s("a", .waitingForYou(.permission)), s("b", .crashed)],
                                            now: t0.addingTimeInterval(1.8))
        XCTAssertEqual(replacement?.kind, .merged)
        XCTAssertEqual(replacement?.sessionIDs, ["a", "b"])
        XCTAssertTrue(p.queue.isEmpty, "merged, not queued")
    }

    func testAttentionOutsideTheWindowQueues() {
        let p = seeded([s("a", .working), s("b", .working)])
        p.sessionsChanged([s("a", .waitingForYou(.permission)), s("b", .working)], now: t0.addingTimeInterval(1))
        _ = p.next(now: t0.addingTimeInterval(1))
        let replacement = p.sessionsChanged([s("a", .waitingForYou(.permission)), s("b", .crashed)],
                                            now: t0.addingTimeInterval(2.5))
        XCTAssertNil(replacement)
        XCTAssertEqual(p.queue.map(\.kind), [.crashed])
    }

    func testTheNextPeekWaitsForTheGapAfterTheLastOne() {
        let p = seeded([s("a", .working), s("b", .working)])
        p.sessionsChanged([s("a", .done), s("b", .done)], now: t0.addingTimeInterval(1))
        XCTAssertEqual(p.next(now: t0.addingTimeInterval(1))?.sessionIDs, ["a"])
        XCTAssertNil(p.next(now: t0.addingTimeInterval(2)), "one at a time")
        p.peekEnded(now: t0.addingTimeInterval(2.5))
        XCTAssertNil(p.next(now: t0.addingTimeInterval(2.7)), "0.2 s < gap")
        XCTAssertEqual(p.next(now: t0.addingTimeInterval(3.0))?.sessionIDs, ["b"])
    }

    /// A queued "waiting" whose session was answered before its turn is dropped.
    func testStaleItemsAreSkipped() {
        let p = seeded([s("a", .working), s("b", .working)])
        p.sessionsChanged([s("a", .done), s("b", .working)], now: t0.addingTimeInterval(1))
        _ = p.next(now: t0.addingTimeInterval(1))
        p.sessionsChanged([s("a", .done), s("b", .waitingForYou(.permission))], now: t0.addingTimeInterval(3))
        p.sessionsChanged([s("a", .done), s("b", .working)], now: t0.addingTimeInterval(4))
        p.peekEnded(now: t0.addingTimeInterval(4))
        XCTAssertNil(p.next(now: t0.addingTimeInterval(5)))
        XCTAssertTrue(p.queue.isEmpty)
    }

    func testLockedCountsInsteadOfPeekingAndUnlockSummarises() {
        let p = seeded([s("a", .working), s("b", .working), s("c", .working)],
                       settings: PeekSettings(onDone: false))
        p.lock()
        p.sessionsChanged([s("a", .done), s("b", .done), s("c", .waitingForYou(.question))],
                          now: t0.addingTimeInterval(60))
        XCTAssertNil(p.next(now: t0.addingTimeInterval(61)))
        p.unlock(now: t0.addingTimeInterval(120))
        let item = p.next(now: t0.addingTimeInterval(120))
        XCTAssertEqual(item?.kind, .away(done: 2, waiting: 1, crashed: 0),
                       "the summary counts everything, switches or not")
    }

    func testUnlockWithNothingToSayIsSilent() {
        let p = seeded([s("a", .working)])
        p.lock()
        p.unlock(now: t0.addingTimeInterval(10))
        XCTAssertNil(p.next(now: t0.addingTimeInterval(10)))
    }
    // MARK: - The open list

    /// The dwell turned the peek into the list: the scheduler must stop waiting for
    /// it and drop what was queued behind it.
    func testOpeningTheListForgetsThePeekAndDropsTheQueue() {
        let p = seeded([s("a", .working), s("b", .working), s("c", .working)])
        p.sessionsChanged([s("a", .waitingForYou(.permission)), s("b", .working), s("c", .working)],
                          now: t0.addingTimeInterval(1))
        XCTAssertNotNil(p.next(now: t0.addingTimeInterval(1)))
        p.sessionsChanged([s("a", .waitingForYou(.permission)), s("b", .crashed), s("c", .working)],
                          now: t0.addingTimeInterval(3))
        XCTAssertEqual(p.queue.count, 1)

        p.listOpened()
        XCTAssertTrue(p.queue.isEmpty)
        p.sessionsChanged([s("a", .waitingForYou(.permission)), s("b", .crashed), s("c", .done)],
                          now: t0.addingTimeInterval(10))
        XCTAssertEqual(p.next(now: t0.addingTimeInterval(10))?.sessionIDs, ["c"])
    }

    /// Within the merge window of the peek the list replaced, a new attention event
    /// must be a peek of its own — not merged into one that is no longer on screen.
    func testAfterTheListOpensNothingMergesIntoTheOldPeek() {
        let p = seeded([s("a", .working), s("b", .working)])
        p.sessionsChanged([s("a", .waitingForYou(.permission)), s("b", .working)], now: t0.addingTimeInterval(1))
        XCTAssertNotNil(p.next(now: t0.addingTimeInterval(1)))
        p.listOpened()
        let replacement = p.sessionsChanged([s("a", .waitingForYou(.permission)), s("b", .crashed)],
                                            now: t0.addingTimeInterval(1.5))
        XCTAssertNil(replacement)
        let item = p.next(now: t0.addingTimeInterval(1.5))
        XCTAssertEqual(item?.kind, .crashed)
        XCTAssertEqual(item?.sessionIDs, ["b"])
    }

    /// The gap spaces peeks out; opening the list is not a peek and does not reset it.
    func testOpeningTheListLeavesTheGapAlone() {
        let p = seeded([s("a", .working), s("b", .working)])
        p.sessionsChanged([s("a", .done), s("b", .working)], now: t0.addingTimeInterval(1))
        _ = p.next(now: t0.addingTimeInterval(1))
        p.peekEnded(now: t0.addingTimeInterval(2))
        p.listOpened()
        p.sessionsChanged([s("a", .done), s("b", .done)], now: t0.addingTimeInterval(2.1))
        XCTAssertNil(p.next(now: t0.addingTimeInterval(2.2)), "still within the gap after the peek")
        XCTAssertEqual(p.next(now: t0.addingTimeInterval(2.41))?.sessionIDs, ["b"])
    }
}
