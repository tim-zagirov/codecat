import XCTest
@testable import CodeCatCore

final class SessionRouteCacheTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_756_400_000)

    private func route(startedAt: Date, updatedAt: Date, pid: pid_t? = 4242) -> SessionRoute {
        SessionRoute(hostPID: pid, hostBundlePath: "/Applications/Claude.app",
                     hostBundleID: "com.anthropic.claudefordesktop", tty: "/dev/ttys001",
                     startedAt: startedAt, updatedAt: updatedAt)
    }

    // MARK: - Pure decisions (no disk)

    func testMergedFillsInAFreshEntryWhenNoneExisted() {
        let merged = SessionRouteCache.merged(
            existing: nil, hostPID: 4242, hostBundlePath: "/Applications/Claude.app",
            hostBundleID: "com.anthropic.claudefordesktop", tty: "/dev/ttys001",
            startedAt: t0, updatedAt: t0.addingTimeInterval(1))
        XCTAssertEqual(merged.hostPID, 4242)
        XCTAssertEqual(merged.hostBundlePath, "/Applications/Claude.app")
        XCTAssertEqual(merged.startedAt, t0)
        XCTAssertEqual(merged.updatedAt, t0.addingTimeInterval(1))
    }

    /// Pins requirement 3 from the task: fields already known must never be
    /// overwritten with nil/empty by a later event that lacks them.
    func testMergedNeverClobbersKnownFieldsWithNilOrEmpty() {
        let existing = route(startedAt: t0, updatedAt: t0)
        let merged = SessionRouteCache.merged(
            existing: existing, hostPID: nil, hostBundlePath: "", hostBundleID: "", tty: "",
            startedAt: t0.addingTimeInterval(999), updatedAt: t0.addingTimeInterval(5))
        XCTAssertEqual(merged.hostPID, existing.hostPID)
        XCTAssertEqual(merged.hostBundlePath, existing.hostBundlePath)
        XCTAssertEqual(merged.hostBundleID, existing.hostBundleID)
        XCTAssertEqual(merged.tty, existing.tty)
    }

    /// A session's true start time is fixed the first time it is recorded — a later
    /// call must never move it, even if it passes a different `startedAt`.
    func testMergedKeepsTheOriginalStartedAt() {
        let existing = route(startedAt: t0, updatedAt: t0)
        let merged = SessionRouteCache.merged(
            existing: existing, hostPID: 4242, hostBundlePath: "/Applications/Claude.app",
            hostBundleID: "com.anthropic.claudefordesktop", tty: "/dev/ttys001",
            startedAt: t0.addingTimeInterval(999), updatedAt: t0.addingTimeInterval(5))
        XCTAssertEqual(merged.startedAt, t0)
    }

    func testMergedUpdatesFieldsThatArriveFresh() {
        let existing = route(startedAt: t0, updatedAt: t0, pid: 1)
        let merged = SessionRouteCache.merged(
            existing: existing, hostPID: 2, hostBundlePath: "/Applications/NewHost.app",
            hostBundleID: "com.example.new", tty: "/dev/ttys009",
            startedAt: t0, updatedAt: t0.addingTimeInterval(5))
        XCTAssertEqual(merged.hostPID, 2)
        XCTAssertEqual(merged.hostBundlePath, "/Applications/NewHost.app")
        XCTAssertEqual(merged.hostBundleID, "com.example.new")
        XCTAssertEqual(merged.tty, "/dev/ttys009")
    }

    func testPrunedKeepsFreshEntriesAndDropsStaleOnes() {
        let fresh = route(startedAt: t0, updatedAt: t0.addingTimeInterval(-6 * 24 * 60 * 60))
        let stale = route(startedAt: t0, updatedAt: t0.addingTimeInterval(-8 * 24 * 60 * 60))
        let entries = ["fresh": fresh, "stale": stale]
        let result = SessionRouteCache.pruned(entries, now: t0, maxAge: 7 * 24 * 60 * 60)
        XCTAssertNotNil(result["fresh"])
        XCTAssertNil(result["stale"])
    }

    func testPrunedKeepsAnEntryExactlyAtTheBoundary() {
        let boundary = route(startedAt: t0, updatedAt: t0.addingTimeInterval(-7 * 24 * 60 * 60))
        let result = SessionRouteCache.pruned(["b": boundary], now: t0, maxAge: 7 * 24 * 60 * 60)
        XCTAssertNotNil(result["b"])
    }

    func testDecodeOfCorruptJSONYieldsEmptyDictionaryWithoutThrowing() {
        let garbage = Data("this is not json { at all".utf8)
        XCTAssertEqual(SessionRouteCache.decode(garbage), [:])
    }

    /// "Запись без startedAt (файл от будущей/прошлой версии формата) → запись
    /// игнорируется целиком" — one malformed entry must not take down the whole file.
    func testDecodeIgnoresAnEntryMissingStartedAtButKeepsOthers() {
        let json = #"""
        {
            "good": {"hostPID":4242,"hostBundlePath":"/Applications/Claude.app",
                      "hostBundleID":"com.anthropic.claudefordesktop","tty":"/dev/ttys001",
                      "startedAt":1756400000,"updatedAt":1756400001},
            "bad": {"hostPID":1,"updatedAt":1756400001}
        }
        """#.data(using: .utf8)!
        let decoded = SessionRouteCache.decode(json)
        XCTAssertNotNil(decoded["good"])
        XCTAssertNil(decoded["bad"])
    }

    func testEncodeThenDecodeRoundTripsOnFixedValues() {
        let entries = ["s1": route(startedAt: t0, updatedAt: t0.addingTimeInterval(1))]
        let data = SessionRouteCache.encode(entries)
        XCTAssertNotNil(data)
        XCTAssertEqual(SessionRouteCache.decode(data!), entries)
    }

    // MARK: - File I/O (temp directory)

    private func tempCacheURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("codecat-route-cache-tests-\(UUID().uuidString).json")
    }

    func testWritingThenLoadingARouteFromANewInstanceRoundTrips() {
        let url = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = SessionRouteCache(url: url)
        writer.record(sessionId: "s1", hostPID: 4242, hostBundlePath: "/Applications/Claude.app",
                      hostBundleID: "com.anthropic.claudefordesktop", tty: "/dev/ttys001",
                      startedAt: t0, now: t0)

        let reader = SessionRouteCache(url: url)
        reader.load(now: t0.addingTimeInterval(1))
        let readBack = reader.route(for: "s1")
        XCTAssertEqual(readBack?.hostPID, 4242)
        XCTAssertEqual(readBack?.hostBundlePath, "/Applications/Claude.app")
        XCTAssertEqual(readBack?.startedAt, t0)
    }

    func testUnknownSessionIdReturnsNil() {
        let cache = SessionRouteCache()
        XCTAssertNil(cache.route(for: "does-not-exist"))
    }

    func testRemoveDeletesTheEntry() {
        let url = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = SessionRouteCache(url: url)
        cache.record(sessionId: "s1", hostPID: 4242, hostBundlePath: "/Applications/Claude.app",
                    hostBundleID: "com.anthropic.claudefordesktop", tty: "/dev/ttys001",
                    startedAt: t0, now: t0)
        cache.remove(sessionId: "s1")
        XCTAssertNil(cache.route(for: "s1"))

        // Also persisted: a fresh instance reading the same file sees no entry either.
        let reloaded = SessionRouteCache(url: url)
        reloaded.load(now: t0)
        XCTAssertNil(reloaded.route(for: "s1"))
    }

    func testLoadOfAMissingFileYieldsAnEmptyCacheWithoutThrowing() {
        let url = tempCacheURL() // never written
        let cache = SessionRouteCache(url: url)
        cache.load(now: t0)
        XCTAssertNil(cache.route(for: "anything"))
    }

    func testLoadOfACorruptFileOnDiskYieldsAnEmptyCacheWithoutThrowing() throws {
        let url = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not valid json {".utf8).write(to: url)
        let cache = SessionRouteCache(url: url)
        cache.load(now: t0)
        XCTAssertNil(cache.route(for: "anything"))
    }

    func testLoadDropsEntriesOlderThanSevenDaysButKeepsFreshOnes() {
        let url = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = SessionRouteCache(url: url)
        cache.record(sessionId: "fresh", hostPID: 1, hostBundlePath: "/a", hostBundleID: "a",
                    tty: "/dev/t1", startedAt: t0, now: t0.addingTimeInterval(-6 * 24 * 60 * 60))
        cache.record(sessionId: "stale", hostPID: 2, hostBundlePath: "/b", hostBundleID: "b",
                    tty: "/dev/t2", startedAt: t0, now: t0.addingTimeInterval(-8 * 24 * 60 * 60))

        let reloaded = SessionRouteCache(url: url)
        reloaded.load(now: t0, maxAge: 7 * 24 * 60 * 60)
        XCTAssertNotNil(reloaded.route(for: "fresh"))
        XCTAssertNil(reloaded.route(for: "stale"))
    }
}
