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

    /// Review item 6: `hostPID`, `hostBundlePath` and `hostBundleID` all describe one
    /// host reading and must be replaced together. A fresh `hostPID` whose
    /// `hostBundleID` lookup failed (e.g. `Bundle(path:)?.bundleIdentifier` returned
    /// nil for the new host) must not inherit the *old* host's bundle id — that would
    /// describe a route pointing at two different hosts at once.
    func testMergedReplacesWholeHostUnitWhenNewPIDArrivesEvenIfBundleIDLookupFails() {
        let existing = route(startedAt: t0, updatedAt: t0, pid: 1) // bundleID "com.anthropic.claudefordesktop"
        let merged = SessionRouteCache.merged(
            existing: existing, hostPID: 2, hostBundlePath: "/Applications/NewHost.app",
            hostBundleID: nil, tty: nil, startedAt: t0, updatedAt: t0.addingTimeInterval(5))
        XCTAssertEqual(merged.hostPID, 2)
        XCTAssertEqual(merged.hostBundlePath, "/Applications/NewHost.app")
        XCTAssertNil(merged.hostBundleID,
                     "a new pid must not inherit the old host's bundle id")
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

    /// Review item 5: `now.timeIntervalSince(updatedAt) <= maxAge` is satisfied by any
    /// *negative* interval too, so a backwards clock jump or a foreign file with a
    /// future `updatedAt` used to survive pruning forever. Comparing the absolute
    /// value catches this.
    func testPrunedDropsFutureDatedEntriesBeyondMaxAge() {
        let future = route(startedAt: t0, updatedAt: t0.addingTimeInterval(8 * 24 * 60 * 60))
        let result = SessionRouteCache.pruned(["f": future], now: t0, maxAge: 7 * 24 * 60 * 60)
        XCTAssertNil(result["f"], "an entry whose updatedAt is further in the future than maxAge must be dropped too")
    }

    func testDecodeOfCorruptJSONYieldsEmptyDictionaryWithoutThrowing() {
        let garbage = Data("this is not json { at all".utf8)
        XCTAssertEqual(SessionRouteCache.decode(garbage), [:])
    }

    /// An entry with no startedAt (a file from a future or past version of the format)
    /// is ignored on its own — one malformed entry must not take down the whole file.
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

    /// Review item 3: the doc comment says `load()`/`save()` are no-ops in the
    /// in-memory (`url == nil`) mode, but `load()` used to fall through and wipe
    /// `entries` regardless. A future test that seeds via `record` and calls `load`
    /// to simulate a restart must not silently get an empty cache and pass for the
    /// wrong reason.
    func testLoadIsANoOpWhenURLIsNil() {
        let cache = SessionRouteCache()
        cache.record(sessionId: "s1", hostPID: 1, hostBundlePath: "/a", hostBundleID: "a",
                    tty: "/dev/t1", startedAt: t0, now: t0)
        cache.load(now: t0.addingTimeInterval(1))
        XCTAssertNotNil(cache.route(for: "s1"),
                        "load() with no url is a declared no-op and must not erase what record wrote")
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
        // maxAge now lives on the instance (review item 2) rather than being passed
        // only to `load`, so both the writer (whose `record` calls prune too) and the
        // reader need it here — a mismatched maxAge on the writer would prune "fresh"
        // away before it ever reaches disk.
        let cache = SessionRouteCache(url: url, maxAge: 7 * 24 * 60 * 60)
        cache.record(sessionId: "fresh", hostPID: 1, hostBundlePath: "/a", hostBundleID: "a",
                    tty: "/dev/t1", startedAt: t0, now: t0.addingTimeInterval(-6 * 24 * 60 * 60))
        cache.record(sessionId: "stale", hostPID: 2, hostBundlePath: "/b", hostBundleID: "b",
                    tty: "/dev/t2", startedAt: t0, now: t0.addingTimeInterval(-8 * 24 * 60 * 60))

        let reloaded = SessionRouteCache(url: url, maxAge: 7 * 24 * 60 * 60)
        reloaded.load(now: t0)
        XCTAssertNotNil(reloaded.route(for: "fresh"))
        XCTAssertNil(reloaded.route(for: "stale"))
    }

    /// Review item 2: previously `pruned` only ran inside `load()`, called once at
    /// startup — so on a machine that leaves CodeCat running for weeks, a session
    /// that ended without `SessionEnd` stayed in `entries`, and therefore in the file
    /// rewritten on every `Stop`, indefinitely. `record` must prune too, using the
    /// `now` it already has — no timer needed.
    func testRecordPrunesStaleEntriesWithoutWaitingForARestart() {
        let url = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = SessionRouteCache(url: url, maxAge: 7 * 24 * 60 * 60)
        // "stale" is already older than maxAge the moment it's recorded — as if this
        // process has been running long enough for it to have gone dead in the past.
        cache.record(sessionId: "stale", hostPID: 1, hostBundlePath: "/a", hostBundleID: "a",
                    tty: "/dev/t1", startedAt: t0, now: t0.addingTimeInterval(-8 * 24 * 60 * 60))
        // A later record for a different, fresh session — no restart in between.
        cache.record(sessionId: "fresh", hostPID: 2, hostBundlePath: "/b", hostBundleID: "b",
                    tty: "/dev/t2", startedAt: t0, now: t0)
        XCTAssertNil(cache.route(for: "stale"),
                    "must be cleared on the very next write, without waiting for a restart")
        XCTAssertNotNil(cache.route(for: "fresh"))
    }
}
