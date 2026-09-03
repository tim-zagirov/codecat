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
        sut.update(shouldPreventSleep: true) // again — no extra calls
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

/// The bridge against instant sleep when `disablesleep` is cleared.
///
/// Measured on a live machine: `pmset -a disablesleep 0` makes the kernel re-read
/// its settings, it sees the idle time accumulated while the flag was up, and sleeps
/// 37 ms later — `sleep reason Software Sleep`. A control run with lid mode off does
/// not sleep at all, so this call is the culprit.
final class LidSleepBridgeTests: XCTestCase {

    private func makeSUT(flagReader: @escaping () -> Bool? = { nil })
        -> (LidSleepController, () -> [String], () -> [Int]) {
        var commands: [String] = []
        var bridges: [Int] = []
        let sut = LidSleepController(
            runner: { args in commands.append(args.joined(separator: " ")); return 0 },
            flagReader: flagReader,
            bridgeRunner: { seconds in bridges.append(seconds); return true })
        return (sut, { commands }, { bridges })
    }

    func testClearingTheFlagBridgesFirst() {
        let (sut, commands, bridges) = makeSUT()
        sut.isEnabled = true
        sut.update(shouldPreventSleep: true)
        XCTAssertEqual(bridges(), [], "raising the flag is not accompanied by a bridge")

        sut.update(shouldPreventSleep: false)

        XCTAssertEqual(bridges(), [LidSleepController.bridgeSeconds],
                       "clearing the flag must put a bridge in place")
        XCTAssertTrue(commands().last!.contains("disablesleep 0"))
    }

    func testExitClearsThroughTheBridgeToo() {
        let (sut, _, bridges) = makeSUT()
        sut.isEnabled = true
        sut.update(shouldPreventSleep: true)
        sut.resetOnExit()
        XCTAssertEqual(bridges(), [LidSleepController.bridgeSeconds],
                       "quitting the app is the main path the bridge exists for")
    }

    func testTurningTheFeatureOffBridges() {
        let (sut, _, bridges) = makeSUT()
        sut.isEnabled = true
        sut.update(shouldPreventSleep: true)
        sut.isEnabled = false
        XCTAssertEqual(bridges(), [LidSleepController.bridgeSeconds])
    }

    /// No bridge where there was no flag: a needless assertion would keep the Mac awake
    /// for a minute for no reason at all.
    func testNoBridgeWhenThereWasNothingToClear() {
        let (sut, _, bridges) = makeSUT()
        sut.isEnabled = true
        sut.update(shouldPreventSleep: false)
        sut.resetOnExit()
        sut.isEnabled = false
        XCTAssertEqual(bridges(), [], "the flag was not up — nothing to clear and nothing to bridge")
    }

    /// The bridge is a convenience, not correctness. If caffeinate did not start, the
    /// flag must still be cleared: leaving disablesleep up is far worse than waking
    /// someone with a screen that went dark.
    func testFlagIsClearedEvenIfTheBridgeFails() {
        var commands: [String] = []
        let sut = LidSleepController(
            runner: { args in commands.append(args.joined(separator: " ")); return 0 },
            flagReader: { nil },
            bridgeRunner: { _ in false })
        sut.isEnabled = true
        sut.update(shouldPreventSleep: true)
        sut.update(shouldPreventSleep: false)

        XCTAssertTrue(commands.last!.contains("disablesleep 0"),
                      "a failed bridge has no right to leave the flag raised")
        XCTAssertFalse(sut.lidSleepDisabled)
    }
}
