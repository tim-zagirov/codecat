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

    func testFailedClearingDoesNotMarkCleared() {
        var callCount = 0
        let sut = LidSleepController(runner: { args in
            let lastArg = args.last ?? ""
            callCount += 1
            // Succeed for "1" (enable), fail for "0" (disable)
            return lastArg == "0" ? 1 : 0
        })
        sut.isEnabled = true
        sut.update(shouldPreventSleep: true)
        sut.update(shouldPreventSleep: false)
        XCTAssertTrue(sut.lidSleepDisabled)
    }

    func testResetOnExitIsNoOpWhenNeverSet() {
        let (sut, calls) = makeSUT()
        sut.isEnabled = true
        // Don't call update at all
        sut.resetOnExit()
        XCTAssertEqual(calls().count, 0)
    }

    // MARK: - reconcile

    func makeSUT(flagReader: @escaping () -> Bool?) -> (LidSleepController, () -> [[String]]) {
        var calls: [[String]] = []
        let sut = LidSleepController(
            runner: { args in calls.append(args); return 0 },
            flagReader: flagReader)
        return (sut, { calls })
    }

    func testReconcileRestoresFlagWhenCacheBelievesSetButRealityIsClear() {
        // Cache says the flag is set, reality says clear, work is ongoing.
        let (sut, calls) = makeSUT(flagReader: { false })
        sut.isEnabled = true
        sut.update(shouldPreventSleep: true) // cache -> believes set, real runner call #1
        XCTAssertEqual(calls().count, 1)

        sut.reconcile(shouldPreventSleep: true)

        XCTAssertEqual(calls(), [
            ["/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "disablesleep", "1"],
            ["/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "disablesleep", "1"],
        ])
        XCTAssertTrue(sut.lidSleepDisabled)
    }

    func testReconcileClearsStaleFlagWhenCacheBelievesClearButRealityIsSet() {
        // Cache says clear, reality says set, no work in progress: a stale flag left by
        // something else (manual pmset, another tool, the watchdog) gets cleaned up.
        let (sut, calls) = makeSUT(flagReader: { true })
        sut.isEnabled = true
        // lidSleepDisabled starts false (cache says clear); never call update(true) first.

        sut.reconcile(shouldPreventSleep: false)

        XCTAssertEqual(calls(), [
            ["/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "disablesleep", "0"],
        ])
        XCTAssertFalse(sut.lidSleepDisabled)
    }

    func testReconcileWithUnreadableStateDoesNothing() {
        let (sut, calls) = makeSUT(flagReader: { nil })
        sut.isEnabled = true
        sut.update(shouldPreventSleep: true) // cache -> believes set
        XCTAssertEqual(calls().count, 1)

        sut.reconcile(shouldPreventSleep: true)

        // No further command: reader was inconclusive, so the cached belief (set) stood,
        // and the decision logic saw shouldPreventSleep == cache, i.e. no-op.
        XCTAssertEqual(calls().count, 1)
        XCTAssertTrue(sut.lidSleepDisabled)
    }

    func testReconcileWithNoDriftIssuesNoRedundantCommand() {
        // Cache matches reality: no drift, so reconcile must not re-issue anything.
        let (sut, calls) = makeSUT(flagReader: { true })
        sut.isEnabled = true
        sut.update(shouldPreventSleep: true) // cache -> believes set, matches reality
        XCTAssertEqual(calls().count, 1)

        sut.reconcile(shouldPreventSleep: true)

        XCTAssertEqual(calls().count, 1)
        XCTAssertTrue(sut.lidSleepDisabled)
    }

    func testUpdateNeverConsultsFlagReader() {
        var readerCalls = 0
        let sut = LidSleepController(
            runner: { _ in 0 },
            flagReader: { readerCalls += 1; return true })
        sut.isEnabled = true
        sut.update(shouldPreventSleep: true)
        sut.update(shouldPreventSleep: true)
        sut.update(shouldPreventSleep: false)
        XCTAssertEqual(readerCalls, 0)
    }

    // MARK: - default reader's pmset -g output parsing

    func testParseSleepDisabledOneReturnsTrue() {
        XCTAssertEqual(
            LidSleepController.parseSleepDisabled(fromPmsetOutput: " SleepDisabled\t\t1\n"),
            true)
    }

    func testParseSleepDisabledZeroReturnsFalse() {
        XCTAssertEqual(
            LidSleepController.parseSleepDisabled(fromPmsetOutput: " SleepDisabled\t\t0\n"),
            false)
    }

    func testParseSleepDisabledMissingLineReturnsNil() {
        let output = """
        System-wide power settings:
        Currently in use:
         standby              1
         hibernatemode        3
        """
        XCTAssertNil(LidSleepController.parseSleepDisabled(fromPmsetOutput: output))
    }
}
