import XCTest
@testable import CodeCatCore

final class LidSleepControllerTests: XCTestCase {
    func makeSUT() -> (LidSleepController, () -> [[String]]) {
        var calls: [[String]] = []
        let sut = LidSleepController(runner: { args in calls.append(args); return 0 })
        return (sut, { calls })
    }

    func testDisabledByDefaultDoesNothing() {
        let (sut, calls) = makeSUT()
        sut.update(shouldPreventSleep: true)
        XCTAssertEqual(calls(), [])
    }

    func testEnabledTogglesPmsetOnAndOffOnce() {
        let (sut, calls) = makeSUT()
        sut.isEnabled = true
        sut.update(shouldPreventSleep: true)
        sut.update(shouldPreventSleep: true) // повторно — без лишних вызовов
        sut.update(shouldPreventSleep: false)
        XCTAssertEqual(calls(), [
            ["/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "disablesleep", "1"],
            ["/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "disablesleep", "0"],
        ])
        XCTAssertFalse(sut.lidSleepDisabled)
    }

    func testTurningToggleOffResetsFlag() {
        let (sut, calls) = makeSUT()
        sut.isEnabled = true
        sut.update(shouldPreventSleep: true)
        sut.isEnabled = false
        XCTAssertEqual(calls().last, ["/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "disablesleep", "0"])
    }

    func testFailedRunnerDoesNotMarkDisabled() {
        let sut = LidSleepController(runner: { _ in 1 })
        sut.isEnabled = true
        sut.update(shouldPreventSleep: true)
        XCTAssertFalse(sut.lidSleepDisabled)
    }

    func testResetOnExitAlwaysSendsZeroIfFlagWasSet() {
        let (sut, calls) = makeSUT()
        sut.isEnabled = true
        sut.update(shouldPreventSleep: true)
        sut.resetOnExit()
        XCTAssertEqual(calls().count, 2)
        XCTAssertEqual(calls().last?.last, "0")
    }
}
