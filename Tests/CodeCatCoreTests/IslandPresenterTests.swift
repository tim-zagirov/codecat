import XCTest
@testable import CodeCatCore

final class IslandPresenterTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_756_400_000)
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    func peek(_ kind: PeekItem.Kind = .waiting) -> PeekItem {
        PeekItem(kind: kind, sessionIDs: ["a"], createdAt: t0)
    }
    /// Deadlines are sums of dates and intervals; around 7.8e8 s since 2001 two
    /// sums of the same value can differ by one ulp, so compare with a tolerance and
    /// tick 10 ms past a boundary.
    func assertDeadline(_ p: IslandPresenter, _ s: TimeInterval, file: StaticString = #filePath, line: UInt = #line) {
        guard let d = p.nextDeadline else { return XCTFail("no deadline", file: file, line: line) }
        XCTAssertEqual(d.timeIntervalSince(t0), s, accuracy: 1e-6, file: file, line: line)
    }

    func testHoverInhalesThenOpensAfterTheDelay() {
        var p = IslandPresenter(hoverDelay: 0.3)
        p.pointerEntered(now: at(0))
        XCTAssertEqual(p.presentation, .inhaled)
        assertDeadline(p, 0.3)
        p.tick(now: at(0.29))
        XCTAssertEqual(p.presentation, .inhaled)
        p.tick(now: at(0.3))
        XCTAssertEqual(p.presentation, .expanded)
    }

    func testPassingThroughNeverOpens() {
        var p = IslandPresenter(hoverDelay: 0.3)
        p.pointerEntered(now: at(0))
        p.pointerLeft(now: at(0.1))
        XCTAssertEqual(p.presentation, .compact)
        p.tick(now: at(1))
        XCTAssertEqual(p.presentation, .compact)
        XCTAssertNil(p.nextDeadline)
    }

    func testLeavingTheExpandedIslandClosesAfterTheDelayUnlessYouComeBack() {
        var p = IslandPresenter(hoverDelay: 0.3)
        p.pointerEntered(now: at(0)); p.tick(now: at(0.3))
        p.pointerLeft(now: at(1))
        assertDeadline(p, 1.15)
        p.pointerEntered(now: at(1.1))
        p.tick(now: at(1.2))
        XCTAssertEqual(p.presentation, .expanded, "came back in time")
        p.pointerLeft(now: at(2))
        p.tick(now: at(2.16))
        XCTAssertEqual(p.presentation, .compact)
    }

    func testAPeekEndsAfterItsHoldAndIsReturned() {
        var p = IslandPresenter()
        let item = peek(.done)
        XCTAssertTrue(p.show(item, now: at(0)))
        XCTAssertEqual(p.presentation, .peek(item))
        assertDeadline(p, 1.5)
        XCTAssertNil(p.tick(now: at(1.4)))
        XCTAssertEqual(p.tick(now: at(1.5)), item)
        XCTAssertEqual(p.presentation, .compact)
    }

    /// Reading the peek must not be cut short: hover pauses the hold, leaving
    /// resumes it with what was left.
    func testHoverPausesTheHold() {
        var p = IslandPresenter(hoverDelay: 5)
        let item = peek()
        p.show(item, now: at(0))
        p.pointerEntered(now: at(1))             // 2 s left
        XCTAssertNil(p.tick(now: at(3.5)), "paused")
        p.pointerLeft(now: at(4))
        assertDeadline(p, 6)
        XCTAssertEqual(p.tick(now: at(6.01)), item)
    }

    func testDwellingOnAPeekOpensTheListAndEndsThePeek() {
        var p = IslandPresenter(hoverDelay: 0.3)
        let item = peek()
        p.show(item, now: at(0))
        p.pointerEntered(now: at(1))
        XCTAssertEqual(p.tick(now: at(1.31)), item, "the peek became the list")
        XCTAssertEqual(p.presentation, .expanded)
    }

    func testAPeekStartingUnderTheCursorWaitsForItToLeave() {
        var p = IslandPresenter(hoverDelay: 5)
        p.pointerEntered(now: at(0))
        let item = peek()
        p.show(item, now: at(0.1))
        XCTAssertEqual(p.presentation, .peek(item))
        XCTAssertNil(p.tick(now: at(4)), "hold paused")
    }

    func testTheExpandedListRefusesPeeks() {
        var p = IslandPresenter(hoverDelay: 0.3)
        p.pointerEntered(now: at(0)); p.tick(now: at(0.3))
        XCTAssertFalse(p.show(peek(), now: at(1)))
        XCTAssertEqual(p.presentation, .expanded)
    }

    func testANewPeekReplacesTheShowingOneAndRestartsItsHold() {
        var p = IslandPresenter()
        p.show(peek(), now: at(0))
        let merged = PeekItem(kind: .merged, sessionIDs: ["a", "b"], createdAt: t0)
        p.show(merged, now: at(0.8))
        XCTAssertEqual(p.presentation, .peek(merged))
        assertDeadline(p, 3.8)
    }

    func testEscapeAndJumpCloseEverything() {
        var p = IslandPresenter(hoverDelay: 0.3)
        p.pointerEntered(now: at(0)); p.tick(now: at(0.3))
        p.escape()
        XCTAssertEqual(p.presentation, .compact)
        let item = peek()
        p.show(item, now: at(1))
        XCTAssertEqual(p.jumped(), item)
        XCTAssertEqual(p.presentation, .compact)
        XCTAssertNil(p.nextDeadline)
    }
    // MARK: - open(now:) — the Show button and a click on the floating cat

    func testOpenFromCompactExpands() {
        var p = IslandPresenter()
        XCTAssertNil(p.open(now: at(0)))
        XCTAssertEqual(p.presentation, .expanded)
        XCTAssertNil(p.nextDeadline)
    }

    /// Opening during the dwell must not leave the dwell armed behind it.
    func testOpenFromInhaledExpandsAndDropsTheDwell() {
        var p = IslandPresenter(hoverDelay: 0.3)
        p.pointerEntered(now: at(0))
        XCTAssertNil(p.open(now: at(0.1)))
        XCTAssertEqual(p.presentation, .expanded)
        XCTAssertNil(p.nextDeadline)
    }

    func testOpenFromAPeekEndsItAndReturnsIt() {
        var p = IslandPresenter()
        let item = peek()
        p.show(item, now: at(0))
        XCTAssertEqual(p.open(now: at(1)), item)
        XCTAssertEqual(p.presentation, .expanded)
        XCTAssertNil(p.nextDeadline, "the hold must not fire on the open list")
    }

    func testOpenWhileExpandedIsANoOp() {
        var p = IslandPresenter(hoverDelay: 0.3)
        p.pointerEntered(now: at(0)); p.tick(now: at(0.3))
        p.pointerLeft(now: at(1))
        XCTAssertNil(p.open(now: at(1.05)))
        XCTAssertEqual(p.presentation, .expanded)
        assertDeadline(p, 1.15)
    }

    func testOnlyThePeekAndTheListCountAsOpen() {
        XCTAssertFalse(IslandPresentation.compact.isOpen)
        XCTAssertFalse(IslandPresentation.inhaled.isOpen)
        XCTAssertTrue(IslandPresentation.expanded.isOpen)
        XCTAssertTrue(IslandPresentation.peek(PeekItem(kind: .done, sessionIDs: ["a"], createdAt: Date())).isOpen)
    }
}
