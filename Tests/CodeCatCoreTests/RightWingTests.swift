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

    func testElapsedTextIsMinutesThenHours() {
        XCTAssertEqual(RightWing.elapsedText(30), "<1m")
        XCTAssertEqual(RightWing.elapsedText(60), "1m")
        XCTAssertEqual(RightWing.elapsedText(59 * 60 + 59), "59m")
        XCTAssertEqual(RightWing.elapsedText(61 * 60), "1h")
        XCTAssertEqual(RightWing.elapsedText(-5), "<1m")
    }
}
