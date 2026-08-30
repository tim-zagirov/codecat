import XCTest
@testable import CodeCatCore

/// Fake process tree: pid -> snapshot, so ancestry logic is testable without syscalls.
private struct FakeTree: ProcessTreeProviding {
    var nodes: [pid_t: ProcessSnapshot]
    func snapshot(for pid: pid_t) -> ProcessSnapshot? { nodes[pid] }
}

private func node(_ pid: pid_t, _ ppid: pid_t, _ path: String?, tty: String? = nil) -> (pid_t, ProcessSnapshot) {
    (pid, ProcessSnapshot(pid: pid, ppid: ppid, executablePath: path, tty: tty))
}

final class ProcessTreeTests: XCTestCase {

    // MARK: - Extracting a bundle path from an executable path

    func testOutermostBundlePathOfAPlainExecutableIsNil() {
        XCTAssertNil(ProcessTree.outermostBundlePath(forExecutablePath: "/bin/zsh"))
    }

    func testOutermostBundlePathOfASimpleBundle() {
        XCTAssertEqual(
            ProcessTree.outermostBundlePath(
                forExecutablePath: "/Applications/Claude.app/Contents/MacOS/Claude"),
            "/Applications/Claude.app")
    }

    /// A helper nested inside its host bundle must resolve to the host, not to itself:
    /// activating the helper does nothing the user can see.
    func testNestedHelperBundleResolvesToTheOutermostBundle() {
        XCTAssertEqual(
            ProcessTree.outermostBundlePath(
                forExecutablePath: "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper"),
            "/Applications/Claude.app")
    }

    func testPathContainingDotAppInAFolderNameIsNotABundle() {
        XCTAssertNil(ProcessTree.outermostBundlePath(forExecutablePath: "/Users/me/my.apple/bin/tool"))
    }

    // MARK: - Walking up to the owning application

    /// The real chain measured on macOS: the Claude Code CLI itself lives in an
    /// .app bundle under Application Support, and there is a helper bundle in
    /// between, so only the *last* bundle ancestor is the app the user sees.
    func testHostIsTheOutermostBundleAncestorNotTheFirstOne() {
        let tree = FakeTree(nodes: Dictionary(uniqueKeysWithValues: [
            node(500, 400, "/Users/me/Library/Application Support/Claude/claude-code/2.1/claude.app/Contents/MacOS/claude"),
            node(400, 300, "/Applications/Claude.app/Contents/Helpers/disclaimer"),
            node(300, 1, "/Applications/Claude.app/Contents/MacOS/Claude"),
            node(1, 0, "/sbin/launchd"),
        ]))
        let host = ProcessTree.host(startingAt: 500, provider: tree)
        XCTAssertEqual(host, HostApplication(pid: 300, bundlePath: "/Applications/Claude.app"))
    }

    func testHostOfATerminalSessionIsTheTerminalApp() {
        let tree = FakeTree(nodes: Dictionary(uniqueKeysWithValues: [
            node(700, 600, "/opt/homebrew/bin/claude", tty: "/dev/ttys001"),
            node(600, 500, "/bin/zsh", tty: "/dev/ttys001"),
            node(500, 1, "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
            node(1, 0, "/sbin/launchd"),
        ]))
        XCTAssertEqual(ProcessTree.host(startingAt: 700, provider: tree),
                       HostApplication(pid: 500, bundlePath: "/System/Applications/Utilities/Terminal.app"))
    }

    func testNoBundleAncestorMeansNoHost() {
        let tree = FakeTree(nodes: Dictionary(uniqueKeysWithValues: [
            node(700, 600, "/opt/homebrew/bin/claude"),
            node(600, 1, "/bin/zsh"),
            node(1, 0, "/sbin/launchd"),
        ]))
        XCTAssertNil(ProcessTree.host(startingAt: 700, provider: tree))
    }

    func testMissingSnapshotStopsTheWalkWithoutCrashing() {
        let tree = FakeTree(nodes: Dictionary(uniqueKeysWithValues: [
            node(700, 600, "/opt/homebrew/bin/claude"),
        ]))
        XCTAssertNil(ProcessTree.host(startingAt: 700, provider: tree))
    }

    /// A corrupt tree must not spin forever inside a hook that Claude Code waits on.
    func testCyclicParentChainTerminates() {
        let tree = FakeTree(nodes: Dictionary(uniqueKeysWithValues: [
            node(10, 20, "/bin/a"),
            node(20, 10, "/bin/b"),
        ]))
        XCTAssertNil(ProcessTree.host(startingAt: 10, provider: tree))
    }

    func testWalkStopsAtMaxDepth() {
        var nodes: [(pid_t, ProcessSnapshot)] = []
        for pid in pid_t(2)...pid_t(60) {
            nodes.append(node(pid, pid + 1, "/bin/link"))
        }
        nodes.append(node(61, 1, "/Applications/Far.app/Contents/MacOS/Far"))
        let tree = FakeTree(nodes: Dictionary(uniqueKeysWithValues: nodes))
        XCTAssertNil(ProcessTree.host(startingAt: 2, provider: tree, maxDepth: 5))
    }

    // MARK: - Never attributing a session to CodeCat itself

    /// The installed hook is `/Applications/CodeCat.app/Contents/MacOS/codecat-hook`,
    /// so its own executable resolves to a bundle. Under tmux/screen/ssh with a
    /// natively installed `claude` there is no `.app` above it, and without an
    /// exclusion the session would be recorded as living in CodeCat itself, pointing
    /// at a pid that exits microseconds later.
    func testTheExcludedBundleIsNeverChosenAsTheHost() {
        let tree = FakeTree(nodes: Dictionary(uniqueKeysWithValues: [
            node(800, 700, "/Applications/CodeCat.app/Contents/MacOS/codecat-hook"),
            node(700, 600, "/opt/homebrew/bin/claude", tty: "/dev/ttys001"),
            node(600, 500, "/opt/homebrew/bin/tmux", tty: "/dev/ttys001"),
            node(500, 1, "/bin/zsh"),
            node(1, 0, "/sbin/launchd"),
        ]))
        XCTAssertNil(ProcessTree.host(startingAt: 800, provider: tree,
                                      excludingBundlePath: "/Applications/CodeCat.app"))
    }

    /// The exclusion must not shadow a real host that happens to sit above the hook.
    func testExcludingCodeCatStillFindsARealHostAboveIt() {
        let tree = FakeTree(nodes: Dictionary(uniqueKeysWithValues: [
            node(800, 700, "/Applications/CodeCat.app/Contents/MacOS/codecat-hook"),
            node(700, 600, "/opt/homebrew/bin/claude", tty: "/dev/ttys001"),
            node(600, 500, "/bin/zsh", tty: "/dev/ttys001"),
            node(500, 1, "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
            node(1, 0, "/sbin/launchd"),
        ]))
        XCTAssertEqual(ProcessTree.host(startingAt: 800, provider: tree,
                                        excludingBundlePath: "/Applications/CodeCat.app"),
                       HostApplication(pid: 500, bundlePath: "/System/Applications/Utilities/Terminal.app"))
    }

    /// No exclusion given (the default) keeps the previous behaviour.
    func testNoExclusionKeepsEveryBundleCandidate() {
        let tree = FakeTree(nodes: Dictionary(uniqueKeysWithValues: [
            node(800, 1, "/Applications/CodeCat.app/Contents/MacOS/codecat-hook"),
            node(1, 0, "/sbin/launchd"),
        ]))
        XCTAssertEqual(ProcessTree.host(startingAt: 800, provider: tree),
                       HostApplication(pid: 800, bundlePath: "/Applications/CodeCat.app"))
    }

    // MARK: - TTY

    func testTtyIsTakenFromTheStartingProcess() {
        let tree = FakeTree(nodes: Dictionary(uniqueKeysWithValues: [
            node(700, 600, "/opt/homebrew/bin/claude", tty: "/dev/ttys003"),
            node(600, 1, "/bin/zsh", tty: "/dev/ttys003"),
        ]))
        XCTAssertEqual(ProcessTree.tty(startingAt: 700, provider: tree), "/dev/ttys003")
    }

    /// A GUI-launched session has no controlling terminal anywhere up the chain.
    func testNoTtyAnywhereMeansNil() {
        let tree = FakeTree(nodes: Dictionary(uniqueKeysWithValues: [
            node(700, 600, "/opt/homebrew/bin/claude"),
            node(600, 1, "/bin/zsh"),
        ]))
        XCTAssertNil(ProcessTree.tty(startingAt: 700, provider: tree))
    }

    /// Claude Code may sit under a wrapper that has no tty of its own while the
    /// shell above it does; the terminal tab is still the right destination.
    func testTtyFallsBackToAnAncestor() {
        let tree = FakeTree(nodes: Dictionary(uniqueKeysWithValues: [
            node(700, 600, "/opt/homebrew/bin/claude"),
            node(600, 500, "/bin/zsh", tty: "/dev/ttys004"),
            node(500, 1, "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
        ]))
        XCTAssertEqual(ProcessTree.tty(startingAt: 700, provider: tree), "/dev/ttys004")
    }

    // MARK: - Live process tree backed by sysctl

    /// The syscall layer cannot be modelled, so it is pinned against the one process
    /// whose facts the test already knows: itself.
    func testLiveTreeReportsThisProcessCorrectly() {
        let snapshot = LiveProcessTree().snapshot(for: getpid())
        XCTAssertEqual(snapshot?.pid, getpid())
        XCTAssertEqual(snapshot?.ppid, getppid())
        XCTAssertNotNil(snapshot?.executablePath)
        XCTAssertTrue(snapshot?.executablePath?.hasPrefix("/") == true)
    }

    func testLiveTreeReturnsNilForAPidThatCannotExist() {
        XCTAssertNil(LiveProcessTree().snapshot(for: -1))
    }

    /// Walking from the test process must reach launchd's children without hanging
    /// or crashing, whatever the real machine's tree looks like.
    func testWalkingTheRealTreeTerminates() {
        _ = ProcessTree.host(startingAt: getpid(), provider: LiveProcessTree())
        _ = ProcessTree.tty(startingAt: getpid(), provider: LiveProcessTree())
    }
}
