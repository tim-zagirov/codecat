import XCTest
@testable import CodeCatCore

final class RightWingTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_759_000_000)

    private func session(_ id: String, _ status: SessionStatus, startedMinutesAgo: Double = 0,
                         steps: [TaskStep] = []) -> Session {
        var s = Session(id: id, projectPath: "/p/\(id)", status: status, activityDescription: "",
                        startedAt: now.addingTimeInterval(-startedMinutesAgo * 60), lastActivity: now)
        s.steps = steps
        return s
    }

    private let fiveSteps = (0..<5).map {
        TaskStep(id: "\($0)", title: "step \($0)", status: $0 < 2 ? .completed : ($0 == 2 ? .inProgress : .pending))
    }

    func testNothingActiveLeavesTheWingEmpty() {
        XCTAssertEqual(RightWing.content(for: [], aggregate: .sleeping, now: now), .empty)
        XCTAssertEqual(RightWing.content(for: [session("a", .idle), session("b", .idle)],
                                         aggregate: .sleeping, now: now), .empty)
    }

    func testOneWorkingSessionShowsItsPlanOrItsAge() {
        XCTAssertEqual(RightWing.content(for: [session("a", .working, steps: fiveSteps), session("b", .idle)],
                                         aggregate: .working, now: now), .progress(done: 2, total: 5))
        XCTAssertEqual(RightWing.content(for: [session("a", .working, startedMinutesAgo: 4)],
                                         aggregate: .working, now: now), .elapsed("4m"))
    }

    func testOneSessionInAnyOtherStateShowsACheckOrItsDot() {
        XCTAssertEqual(RightWing.content(for: [session("a", .done)], aggregate: .done, now: now), .check)
        XCTAssertEqual(RightWing.content(for: [session("a", .waitingForYou(.permission))],
                                         aggregate: .waiting, now: now), .dot(.waiting))
        XCTAssertEqual(RightWing.content(for: [session("a", .crashed)], aggregate: .problem, now: now),
                       .dot(.problem))
    }

    func testTwoToFourSessionsAreADotEachInListOrder() {
        let ordered = [session("w", .waitingForYou(.question)), session("a", .working), session("i", .idle),
                       session("d", .done)]
        XCTAssertEqual(RightWing.content(for: ordered, aggregate: .waiting, now: now),
                       .dots([SessionDot(id: "w", tone: .waiting), SessionDot(id: "a", tone: .working),
                              SessionDot(id: "d", tone: .done)]))
    }

    func testFiveOrMoreCollapseToTheAggregateAndACount() {
        let ordered = (0..<6).map { session("s\($0)", .working) }
        XCTAssertEqual(RightWing.content(for: ordered, aggregate: .working, now: now), .count(.working, 6))
    }

    // MARK: The open header (§5.3)

    /// `IslandLayout.headerDotsRoom` on this Mac's 185 pt notch.
    private let room: CGFloat = 65.5

    func testHeaderRoomIsTheGapBetweenTheNotchAndSettings() {
        // 420 / 2 − 20 inset − 22 "•••" − 10 gap − 185 / 2
        XCTAssertEqual(IslandLayout.headerDotsRoom(notchWidth: 185), 65.5)
    }

    func testHeaderShowsOneSessionAsItsDotNeverTheRingOrTheCheck() {
        XCTAssertEqual(RightWing.header(for: [session("a", .working, steps: fiveSteps), session("i", .idle)],
                                        aggregate: .working, room: room),
                       .dots([SessionDot(id: "a", tone: .working)]))
        XCTAssertEqual(RightWing.header(for: [session("a", .done)], aggregate: .done, room: room),
                       .dots([SessionDot(id: "a", tone: .done)]))
        XCTAssertEqual(RightWing.header(for: [session("i", .idle)], aggregate: .sleeping, room: room), .empty)
    }

    func testHeaderShowsTwoToFourAsADotEachWhileTheyFit() {
        // Three waiting and one working: 3 × 13 + 7 + 3 × 5 = 61 ≤ 65.5.
        let ordered = [session("w1", .waitingForYou(.question)), session("w2", .waitingForYou(.permission)),
                       session("w3", .waitingForYou(.question)), session("a", .working)]
        XCTAssertEqual(RightWing.rowWidth(RightWing.header(for: ordered, aggregate: .waiting, room: room).dots), 61)
        XCTAssertEqual(RightWing.header(for: ordered, aggregate: .waiting, room: room),
                       .dots([SessionDot(id: "w1", tone: .waiting), SessionDot(id: "w2", tone: .waiting),
                              SessionDot(id: "w3", tone: .waiting), SessionDot(id: "a", tone: .working)]))
    }

    func testHeaderFallsBackToTheCountWhenFourDotsWouldReachUnderTheNotch() {
        // Four halos: 4 × 13 + 3 × 5 = 67 > 65.5.
        let ordered = (0..<4).map { session("w\($0)", .waitingForYou(.question)) }
        XCTAssertEqual(RightWing.header(for: ordered, aggregate: .waiting, room: room), .count(.waiting, 4))
    }

    func testHeaderCountsFiveOrMoreHoweverFewWait() {
        let five = [session("w1", .waitingForYou(.question)), session("w2", .waitingForYou(.question))]
            + (0..<3).map { session("s\($0)", .working) }
        XCTAssertEqual(RightWing.header(for: five, aggregate: .waiting, room: room), .count(.waiting, 5))
        let seven = (0..<7).map { session("s\($0)", .working) }
        XCTAssertEqual(RightWing.header(for: seven, aggregate: .working, room: room), .count(.working, 7))
    }

    func testRowWidthMatchesTheDotsLayout() {
        XCTAssertEqual(RightWing.rowWidth([]), 0)
        XCTAssertEqual(RightWing.rowWidth([SessionDot(id: "a", tone: .working)]), 7)
        XCTAssertEqual(RightWing.rowWidth((0..<6).map { SessionDot(id: "\($0)", tone: .working) }), 67)
    }

    func testElapsedTextIsMinutesThenHours() {
        XCTAssertEqual(RightWing.elapsedText(30), "<1m")
        XCTAssertEqual(RightWing.elapsedText(60), "1m")
        XCTAssertEqual(RightWing.elapsedText(59 * 60 + 59), "59m")
        XCTAssertEqual(RightWing.elapsedText(61 * 60), "1h")
        XCTAssertEqual(RightWing.elapsedText(-5), "<1m")
    }
}

private extension RightWing {
    var dots: [SessionDot] {
        if case .dots(let dots) = self { return dots }
        return []
    }
}
