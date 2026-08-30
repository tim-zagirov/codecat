import XCTest
@testable import CodeCatCore

final class AwayLogTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_756_400_000)

    func testRecordsOnlyWhileAway() {
        let log = AwayLog()
        log.record("до блокировки", at: t0)
        log.lock()
        log.record("сессия couchdeck закончила", at: t0.addingTimeInterval(60))
        log.unlock()
        XCTAssertEqual(log.lastSummary.map(\.text), ["сессия couchdeck закончила"])
    }

    func testUnlockKeepsSummaryUntilNextLock() {
        let log = AwayLog()
        log.lock()
        log.record("x", at: t0.addingTimeInterval(1))
        log.unlock()
        XCTAssertEqual(log.lastSummary.count, 1)
        log.lock()
        XCTAssertEqual(log.lastSummary.count, 0, "новая блокировка начинает новый сбор")
    }

    func testIsAwayFlag() {
        let log = AwayLog()
        XCTAssertFalse(log.isAway)
        log.lock()
        XCTAssertTrue(log.isAway)
        log.unlock()
        XCTAssertFalse(log.isAway)
    }

    func testDuplicateUnlockPreservesSummary() {
        let log = AwayLog()
        log.lock()
        log.record("event while away", at: t0)
        log.unlock()
        XCTAssertEqual(log.lastSummary.count, 1)
        XCTAssertEqual(log.lastSummary[0].text, "event while away")

        // Second unlock should not overwrite the summary
        log.unlock()
        XCTAssertEqual(log.lastSummary.count, 1, "duplicate unlock should not wipe the summary")
        XCTAssertEqual(log.lastSummary[0].text, "event while away")
    }

    func testDuplicateLockPreservesCollectedEvents() {
        let log = AwayLog()
        log.lock()
        log.record("event 1", at: t0)

        // Second lock should not discard the collected event
        log.lock()
        log.record("event 2", at: t0.addingTimeInterval(1))
        log.unlock()

        XCTAssertEqual(log.lastSummary.count, 2, "duplicate lock should not discard previously collected events")
        XCTAssertEqual(log.lastSummary[0].text, "event 1")
        XCTAssertEqual(log.lastSummary[1].text, "event 2")
    }

    func testUnlockWithoutLockDoesNotCrash() {
        let log = AwayLog()
        XCTAssertFalse(log.isAway)

        // Calling unlock on a fresh log that was never locked should be a no-op
        log.unlock()
        XCTAssertFalse(log.isAway, "unlock on fresh log should not change isAway")
        XCTAssertEqual(log.lastSummary.count, 0, "unlock on fresh log should not create a summary")
    }
}
