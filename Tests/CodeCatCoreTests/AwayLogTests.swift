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
}
