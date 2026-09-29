import XCTest
@testable import CodeCatCore

/// `PeekScheduler` and `IslandPresenter` driven together, the way the island
/// controller drives them. Each is tested alone elsewhere; what these tests hold is
/// the handshake between them — a scheduler that thinks a peek is still on screen
/// when the island has moved on never offers another one.
final class IslandPeekFlowTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_756_400_000)
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    /// The caller's side of the protocol documented on `PeekScheduler`, and nothing
    /// more: ask for a peek only while the island is compact or inhaled, hand every
    /// peek the presenter ends to `peekEnded`, and tell the scheduler when the list
    /// is open.
    final class Flow {
        let scheduler = PeekScheduler()
        var presenter = IslandPresenter(hoverDelay: 0.3)
        private var statuses: [String: SessionStatus] = [:]
        private let t0: Date

        init(t0: Date, sessions: [String]) {
            self.t0 = t0
            for id in sessions { statuses[id] = .working }
            scheduler.sessionsChanged(currentSessions, now: t0)
        }

        var presentation: IslandPresentation { presenter.presentation }

        private var currentSessions: [Session] {
            statuses.keys.sorted().map {
                Session(id: $0, projectPath: "/p/\($0)", status: statuses[$0]!,
                        activityDescription: "", startedAt: t0, lastActivity: t0)
            }
        }

        func set(_ id: String, _ status: SessionStatus, now: Date) {
            statuses[id] = status
            if let replacement = scheduler.sessionsChanged(currentSessions, now: now) {
                presenter.show(replacement, now: now)
            }
            settle(now: now)
        }

        func tick(_ now: Date) { ended(presenter.tick(now: now), now: now) }
        func pointerEntered(_ now: Date) { presenter.pointerEntered(now: now); settle(now: now) }
        func pointerLeft(_ now: Date) { presenter.pointerLeft(now: now); settle(now: now) }
        func escape(_ now: Date) { ended(presenter.escape(), now: now) }
        func jumped(_ now: Date) { ended(presenter.jumped(), now: now) }
        func open(_ now: Date) { ended(presenter.open(now: now), now: now) }

        private func ended(_ item: PeekItem?, now: Date) {
            if item != nil { scheduler.peekEnded(now: now) }
            settle(now: now)
        }

        private func settle(now: Date) {
            switch presenter.presentation {
            case .expanded:
                scheduler.listOpened()
            case .compact, .inhaled:
                if let item = scheduler.next(now: now) { presenter.show(item, now: now) }
            case .peek:
                break
            }
        }
    }

    func peekedSessions(_ flow: Flow) -> [String]? {
        if case .peek(let item) = flow.presentation { return item.sessionIDs }
        return nil
    }

    /// (a) The list already shows everything: what happens while it is open does not
    /// come back as a peek after it closes — and the scheduler is not left believing
    /// a peek is on screen, so the next event still peeks.
    func testWhatHappensWhileTheListIsOpenIsDroppedAndPeeksResumeAfterItCloses() {
        let flow = Flow(t0: t0, sessions: ["a", "b", "c"])
        flow.set("a", .waitingForYou(.permission), now: at(1))
        XCTAssertEqual(peekedSessions(flow), ["a"])

        flow.pointerEntered(at(1.5))
        flow.tick(at(1.81))
        XCTAssertEqual(flow.presentation, .expanded, "the dwell turned the peek into the list")

        flow.set("b", .waitingForYou(.permission), now: at(3))
        XCTAssertEqual(flow.presentation, .expanded)

        flow.pointerLeft(at(4))
        flow.tick(at(4.16))
        XCTAssertEqual(flow.presentation, .compact, "b was seen in the open list")
        flow.tick(at(10))
        XCTAssertEqual(flow.presentation, .compact)

        flow.set("c", .crashed, now: at(11))
        XCTAssertEqual(peekedSessions(flow), ["c"])
    }

    /// (b) Escape ends the peek; the next one waits out the 0.4 s gap.
    func testAfterEscapeTheNextPeekComesAfterTheGap() {
        let flow = Flow(t0: t0, sessions: ["a", "b"])
        flow.set("a", .waitingForYou(.permission), now: at(1))
        flow.set("b", .crashed, now: at(2.5))          // outside the merge window: queued
        XCTAssertEqual(peekedSessions(flow), ["a"])

        flow.escape(at(2.6))
        XCTAssertEqual(flow.presentation, .compact)
        flow.tick(at(2.9))
        XCTAssertEqual(flow.presentation, .compact, "within the gap")
        flow.tick(at(3.01))
        XCTAssertEqual(peekedSessions(flow), ["b"])
    }

    /// (c) A jump from the peek ends it like escape does.
    func testAJumpFromThePeekEndsItAndTheQueueCarriesOn() {
        let flow = Flow(t0: t0, sessions: ["a", "b"])
        flow.set("a", .waitingForYou(.permission), now: at(1))
        flow.set("b", .crashed, now: at(2.5))
        flow.jumped(at(2.6))
        XCTAssertEqual(flow.presentation, .compact)
        flow.tick(at(3.01))
        XCTAssertEqual(peekedSessions(flow), ["b"])
    }

    /// (d) A second session within the merge window replaces the peek on screen and
    /// restarts its hold; its end is the merged item's end.
    func testAMergeReplacesThePeekAndRestartsTheHold() {
        let flow = Flow(t0: t0, sessions: ["a", "b"])
        flow.set("a", .waitingForYou(.permission), now: at(0))
        flow.set("b", .waitingForYou(.question), now: at(0.8))
        XCTAssertEqual(peekedSessions(flow), ["a", "b"])
        guard case .peek(let merged) = flow.presentation else { return XCTFail("no peek") }
        XCTAssertEqual(merged.kind, .merged)

        flow.tick(at(3.5))
        XCTAssertEqual(flow.presentation, .peek(merged), "the hold restarted at 0.8")
        flow.tick(at(3.81))
        XCTAssertEqual(flow.presentation, .compact)

        flow.set("a", .working, now: at(5))
        flow.set("a", .crashed, now: at(6))
        XCTAssertEqual(peekedSessions(flow), ["a"], "the scheduler was not left holding the merged peek")
    }

    /// (e) Show on a merged peek opens the list and ends the peek.
    func testOpeningDuringAPeekEndsIt() {
        let flow = Flow(t0: t0, sessions: ["a", "b", "c"])
        flow.set("a", .waitingForYou(.permission), now: at(0))
        flow.set("b", .crashed, now: at(2))            // queued behind a
        flow.open(at(2.2))
        XCTAssertEqual(flow.presentation, .expanded)
        XCTAssertNil(flow.presenter.nextDeadline, "no hold left to fire on the list")

        flow.escape(at(3))
        XCTAssertEqual(flow.presentation, .compact, "b was in the list; the queue went with it")
        flow.tick(at(10))
        XCTAssertEqual(flow.presentation, .compact)

        flow.set("c", .waitingForYou(.question), now: at(11))
        XCTAssertEqual(peekedSessions(flow), ["c"])
    }
}
