import XCTest
@testable import CodeCatCore

final class MockAssertion: SleepAssertionHolding {
    var isHeld = false
    func acquire() { isHeld = true }
    func release() { isHeld = false }
}

final class PowerManagerTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_756_400_000)

    func makeSUT(grace: TimeInterval = 120, floor: Int = 15,
                 battery: @escaping () -> Int? = { nil })
        -> (PowerManager, MockAssertion) {
        let mock = MockAssertion()
        let pm = PowerManager(assertion: mock, gracePeriod: grace,
                              batteryFloor: floor, batteryLevel: battery)
        return (pm, mock)
    }

    func testAcquiresWhenWorkStarts() {
        let (pm, mock) = makeSUT()
        pm.update(anyWorking: true, now: t0)
        XCTAssertTrue(mock.isHeld)
    }

    func testHoldsThroughGracePeriodThenReleases() {
        let (pm, mock) = makeSUT(grace: 120)
        pm.update(anyWorking: true, now: t0)
        pm.update(anyWorking: false, now: t0.addingTimeInterval(60))
        XCTAssertTrue(mock.isHeld, "still held during the grace period")
        pm.tick(now: t0.addingTimeInterval(60 + 119))
        XCTAssertTrue(mock.isHeld)
        pm.tick(now: t0.addingTimeInterval(60 + 121))
        XCTAssertFalse(mock.isHeld)
    }

    func testWorkResumingCancelsPendingRelease() {
        let (pm, mock) = makeSUT(grace: 120)
        pm.update(anyWorking: true, now: t0)
        pm.update(anyWorking: false, now: t0.addingTimeInterval(10))
        pm.update(anyWorking: true, now: t0.addingTimeInterval(20))
        pm.tick(now: t0.addingTimeInterval(500))
        XCTAssertTrue(mock.isHeld, "work resumed — do not release")
    }

    func testDisabledManagerNeverAcquiresAndReleasesExisting() {
        let (pm, mock) = makeSUT()
        pm.update(anyWorking: true, now: t0)
        XCTAssertTrue(mock.isHeld)
        pm.isEnabled = false
        pm.update(anyWorking: true, now: t0.addingTimeInterval(1))
        XCTAssertFalse(mock.isHeld)
    }

    func testLowBatteryReleasesImmediately() {
        var level = 50
        let (pm, mock) = makeSUT(floor: 15, battery: { level })
        pm.update(anyWorking: true, now: t0)
        XCTAssertTrue(mock.isHeld)
        level = 10
        pm.tick(now: t0.addingTimeInterval(30))
        XCTAssertFalse(mock.isHeld, "battery below the floor — release at once")
    }

    func testNilBatteryMeansNoRestriction() {
        let (pm, mock) = makeSUT(battery: { nil })
        pm.update(anyWorking: true, now: t0)
        pm.tick(now: t0.addingTimeInterval(30))
        XCTAssertTrue(mock.isHeld)
    }

    func testBatteryRecoveryReacquiresWhileWorkOngoing() {
        var level = 10
        let (pm, mock) = makeSUT(floor: 15, battery: { level })
        pm.update(anyWorking: true, now: t0)
        XCTAssertFalse(mock.isHeld, "battery is already below the floor — do not take an assertion")
        level = 50
        pm.tick(now: t0.addingTimeInterval(10))
        XCTAssertTrue(mock.isHeld, "battery recovered and work continues — take it again")
    }

    func testNeverLeaksAssertionAcrossMixedTransitions() {
        var level: Int? = 50
        let (pm, mock) = makeSUT(grace: 100, floor: 15, battery: { level })

        pm.update(anyWorking: true, now: t0)
        XCTAssertTrue(mock.isHeld)

        // Work stops, grace period begins, but battery drops before it elapses.
        pm.update(anyWorking: false, now: t0.addingTimeInterval(5))
        level = 5
        pm.tick(now: t0.addingTimeInterval(10))
        XCTAssertFalse(mock.isHeld, "a low battery releases immediately, even in the grace period")

        // Battery recovers, but there is no more work — must stay released.
        level = 80
        pm.tick(now: t0.addingTimeInterval(20))
        XCTAssertFalse(mock.isHeld, "no work — do not take an assertion just because the battery is fine")

        // Work resumes and the feature is disabled at the same moment: must not hold.
        pm.update(anyWorking: true, now: t0.addingTimeInterval(30))
        XCTAssertTrue(mock.isHeld)
        pm.isEnabled = false
        XCTAssertFalse(mock.isHeld, "switching off releases immediately")
        pm.tick(now: t0.addingTimeInterval(1000))
        XCTAssertFalse(mock.isHeld, "switched off — a tick must not take an assertion again")
    }
}
