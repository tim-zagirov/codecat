import XCTest
@testable import CodeCatCore

final class PowerFooterTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_759_000_000)

    func testHoldingSaysHowManyAgentsKeepTheMacAwake() {
        let footer = PowerFooter.make(isHolding: true, releaseDeadline: nil, workingCount: 2, lidModeOn: false, now: now)
        XCTAssertEqual(footer.left, .awake(agents: 2))
        XCTAssertEqual(footer.leftText, "Mac stays awake — 2 agents working")
        XCTAssertEqual(PowerFooter.make(isHolding: true, releaseDeadline: nil, workingCount: 1, lidModeOn: false,
                                        now: now).leftText,
                       "Mac stays awake — 1 agent working")
    }

    /// Handover contract 6: during the grace period both are set — the deadline wins.
    func testTheGracePeriodCountsDownInWholeMinutesRoundedUp() {
        func minutes(_ seconds: TimeInterval) -> PowerFooter.Left? {
            PowerFooter.make(isHolding: true, releaseDeadline: now.addingTimeInterval(seconds),
                             workingCount: 0, lidModeOn: false, now: now).left
        }
        XCTAssertEqual(minutes(90), .sleepsIn(minutes: 2))
        XCTAssertEqual(minutes(60), .sleepsIn(minutes: 1))
        XCTAssertEqual(minutes(61), .sleepsIn(minutes: 2))
        XCTAssertEqual(minutes(1), .sleepsIn(minutes: 1))
    }

    /// The 15 s maintenance tick can leave the deadline in the past: clamp, never "-1 min".
    func testADeadlineInThePastMeansNow() {
        let footer = PowerFooter.make(isHolding: true, releaseDeadline: now.addingTimeInterval(-5),
                                      workingCount: 0, lidModeOn: false, now: now)
        XCTAssertEqual(footer.left, .sleepsIn(minutes: 0))
        XCTAssertEqual(footer.leftText, "Mac can sleep now")
        XCTAssertEqual(PowerFooter.make(isHolding: true, releaseDeadline: now.addingTimeInterval(60),
                                        workingCount: 0, lidModeOn: false, now: now).leftText,
                       "Mac can sleep in 1 min")
    }

    func testNothingToSayMeansNoFooter() {
        let footer = PowerFooter.make(isHolding: false, releaseDeadline: nil, workingCount: 0, lidModeOn: false, now: now)
        XCTAssertTrue(footer.isEmpty)
        XCTAssertEqual(footer, .none)
        let lidOnly = PowerFooter.make(isHolding: false, releaseDeadline: nil, workingCount: 0, lidModeOn: true, now: now)
        XCTAssertFalse(lidOnly.isEmpty)
        XCTAssertNil(lidOnly.leftText)
        XCTAssertTrue(lidOnly.lidOn)
    }
}
