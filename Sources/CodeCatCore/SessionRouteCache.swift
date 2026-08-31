import Foundation

/// Everything known about where a session lives, plus when it started.
///
/// See `docs/superpowers/specs/2026-08-31-route-cache-and-subagents.md`, «1.
/// Кэшируются маршруты, а не сессии», for why this exists at all: `SessionStore`
/// only keeps sessions in memory, so a CodeCat restart (every rebuild during
/// development; every app update or logout for a user) forgot where a
/// still-running session lived, leaving its row permanently unclickable and its
/// "длится N мин" counted from the moment the transcript watcher happened to
/// notice it rather than from the session's real start.
public struct SessionRoute: Codable, Equatable, Sendable {
    public let hostPID: pid_t?
    public let hostBundlePath: String?
    public let hostBundleID: String?
    public let tty: String?
    public let startedAt: Date
    /// When this entry was last touched. Pruning uses this field, never
    /// `startedAt`: a session that has genuinely been running for two
    /// weeks must not be pruned out from under it just because it started long
    /// ago — only a route nobody has confirmed in seven days is presumed dead.
    public let updatedAt: Date

    public init(hostPID: pid_t?, hostBundlePath: String?, hostBundleID: String?,
                tty: String?, startedAt: Date, updatedAt: Date) {
        self.hostPID = hostPID
        self.hostBundlePath = hostBundlePath
        self.hostBundleID = hostBundleID
        self.tty = tty
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }
}

/// A small persisted map from session id to `SessionRoute`, backing the "click a
/// session row after CodeCat restarted" fix.
///
/// **Nothing here ever creates a session.** This cache only ever answers point
/// lookups by id (`route(for:)`), consulted by `SessionStore` at the moment a
/// session first appears from live activity (a hook event or a transcript
/// line). Nobody iterates its contents to conjure sessions back into
/// existence — doing so would resurrect phantom rows for sessions that died
/// long ago, exactly the failure mode a *session* cache (as opposed to a
/// *route* cache) would have after a reboot. `entries` is therefore private:
/// the type itself enforces that nobody outside can iterate it.
///
/// File I/O (`load`/`save`) is intentionally the only impure part. The
/// decisions that matter — how a record merges with newly-arrived fields, and
/// which entries survive a prune — are plain static functions below, so they
/// can be tested on fixed values without ever touching disk. `SessionStore`'s
/// own tests inject a `SessionRouteCache(url: nil)` for the same reason: `load`
/// and `save` become true no-ops, so seeding/reading the cache in a test never
/// touches the filesystem either.
public final class SessionRouteCache {
    /// `nil` in-memory-only mode: `load()`/`save()` are no-ops. Used by
    /// `SessionStore`'s tests, and by any other caller that wants a scratch
    /// cache with no disk footprint.
    private let url: URL?
    /// Entries older than this (by `updatedAt`) are dropped — both at `load()`
    /// and on every `record()` (see there for why the latter matters). Stored on
    /// the instance, not threaded through individual calls, so both places agree
    /// on the same rule without a caller having to repeat it.
    private let maxAge: TimeInterval
    private var entries: [String: SessionRoute] = [:]

    public init(url: URL? = nil, maxAge: TimeInterval = 7 * 24 * 60 * 60) {
        self.url = url
        self.maxAge = maxAge
    }

    /// Reads the cache file once (call at startup). A missing file, a corrupt
    /// or unreadable one, all yield an empty cache with no error surfaced —
    /// there is nothing for the user to fix, so nothing is reported. Entries
    /// older than `maxAge` (by `updatedAt`) are dropped immediately so the file
    /// does not grow forever and a week-old route is never trusted.
    ///
    /// A true no-op in in-memory mode (`url == nil`): it must not clear
    /// whatever `record` has already put in `entries` in that mode.
    public func load(now: Date = Date()) {
        guard let url else { return }
        guard let data = try? Data(contentsOf: url) else {
            entries = [:]
            return
        }
        entries = Self.pruned(Self.decode(data), now: now, maxAge: maxAge)
    }

    /// Everything known about `sessionId`'s route, or `nil` if the cache has
    /// never heard of it (or it was pruned/removed). Deliberately does **not**
    /// check whether `hostPID` still refers to a live process — see the design
    /// spec: that is already checked twice downstream, in `SessionRouter.route`
    /// (`isProcessRunning`) and again in `SystemJumpExecutor.activate` (which
    /// compares the resolved process's bundle path, since macOS recycles pids).
    /// A third check here, on a machine that may have just rebooted, would only
    /// give false confidence — the pid could coincidentally belong to something
    /// else already, or to nothing, and either way the downstream checks catch
    /// it correctly. Skipping it here keeps this type a pure lookup.
    public func route(for sessionId: String) -> SessionRoute? {
        entries[sessionId]
    }

    /// Merges newly-arrived route fields into whatever is already known for
    /// `sessionId` (see `merged(existing:...)` for the never-clobber rule) and
    /// persists immediately. Called only when a hook event actually carries
    /// route fields — see `SessionStore.upsert`.
    ///
    /// Also prunes, using the `now` it already has: `Stop` fires at the end of
    /// every assistant turn, so without this a process left running for weeks
    /// would only ever shrink the file at the next `load()` (i.e. never, short
    /// of a restart) while entries for sessions that ended without
    /// `SessionEnd` accumulate forever. No timer needed — every `record` call
    /// is itself an opportunity to sweep.
    ///
    /// This prunes against the caller-supplied `now`, and `pruned` compares the
    /// *absolute* interval — so a system clock that jumps backwards by more than
    /// `maxAge` wipes the whole cache right here, on the very next `Stop`, rather
    /// than only at the next `load()`. That is a deliberate trade-off, not an
    /// oversight: nothing distinguishes "clock jumped" from "file is a week old"
    /// from inside `pruned`, and losing the cache is the same silent, non-fatal
    /// degradation described under "Обработка ошибок" either way.
    ///
    /// - Parameter resetStartedAt: true for a genuine `SessionStart` (any
    ///   `source` other than `"compact"`) — see `merged` for what this changes.
    public func record(sessionId: String, hostPID: pid_t?, hostBundlePath: String?,
                        hostBundleID: String?, tty: String?, startedAt: Date, now: Date,
                        resetStartedAt: Bool = false) {
        entries[sessionId] = Self.merged(
            existing: entries[sessionId], hostPID: hostPID, hostBundlePath: hostBundlePath,
            hostBundleID: hostBundleID, tty: tty, startedAt: startedAt, updatedAt: now,
            resetStartedAt: resetStartedAt)
        entries = Self.pruned(entries, now: now, maxAge: maxAge)
        save()
    }

    /// The session ended — `SessionEnd` calls this. Nothing left to remember.
    public func remove(sessionId: String) {
        entries.removeValue(forKey: sessionId)
        save()
    }

    /// Silent on failure (no permission, full disk): losing the cache write only
    /// degrades behaviour back to today's (no persisted route), never worse, and
    /// there is no user-actionable fix to surface.
    private func save() {
        guard let url, let data = Self.encode(entries) else { return }
        // .atomic: a crash or full disk mid-write must never leave a truncated
        // routes.json — same pattern as `HooksInstaller`/`AppState.installHooksIfNeeded`.
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Pure decisions (testable on fixed values, no disk)

    /// Combines `existing` with newly-arrived fields. A `nil`/empty incoming
    /// field never clears a field already known — an event that lost its
    /// enrichment (older hook binary, a payload that failed to parse) must not
    /// blank out a route an earlier, fully-enriched event already recorded.
    ///
    /// `hostPID`, `hostBundlePath` and `hostBundleID` all describe one host
    /// reading (`ProcessTree.host`, plus a separate `Bundle(path:)?.bundleIdentifier`
    /// lookup that can independently fail) and are therefore replaced **as a
    /// unit** whenever a fresh `hostPID` arrives, never field by field: a fresh
    /// `hostPID` paired with a failed `hostBundleID` lookup must come out as
    /// "unknown bundle id for the new host", not as the *previous* host's
    /// bundle id — that would describe a route pointing at two different hosts
    /// at once. When no fresh `hostPID` arrives, the whole existing unit is
    /// kept untouched for the same reason.
    ///
    /// `startedAt` is normally accepted only once: a session's real start time
    /// never moves once the cache has it — this is what makes a session
    /// surviving a bare CodeCat restart (no `SessionStart` fires) keep its true
    /// duration. `resetStartedAt` is the deliberate exception: a genuine new
    /// `SessionStart` (`source` anything other than `"compact"`) means whatever
    /// the cache remembered is presumed stale — the session that owned it
    /// either ended without `SessionEnd` (closed terminal, SIGKILL) or is a
    /// fresh `--resume`, either way `startedAt` must reflect the event's own
    /// time instead.
    public static func merged(existing: SessionRoute?, hostPID: pid_t?, hostBundlePath: String?,
                               hostBundleID: String?, tty: String?, startedAt: Date,
                               updatedAt: Date, resetStartedAt: Bool = false) -> SessionRoute {
        let host: (pid: pid_t?, bundlePath: String?, bundleID: String?)
        if let hostPID {
            host = (hostPID, nonEmpty(hostBundlePath), nonEmpty(hostBundleID))
        } else {
            host = (existing?.hostPID, existing?.hostBundlePath, existing?.hostBundleID)
        }
        return SessionRoute(
            hostPID: host.pid,
            hostBundlePath: host.bundlePath,
            hostBundleID: host.bundleID,
            tty: nonEmpty(tty) ?? existing?.tty,
            startedAt: resetStartedAt ? startedAt : (existing?.startedAt ?? startedAt),
            updatedAt: updatedAt)
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    /// Drops entries whose `updatedAt` is more than `maxAge` away from `now`, in
    /// either direction. Pure so the seven-day rule is pinned against fixed
    /// dates, not a real clock.
    ///
    /// Compares the absolute value deliberately: a plain
    /// `now.timeIntervalSince(updatedAt) <= maxAge` is satisfied by any
    /// *negative* interval too (an `updatedAt` in the future), so a backwards
    /// clock jump or a foreign/corrupted file would leave such an entry alive
    /// forever instead of being swept like everything else.
    public static func pruned(_ entries: [String: SessionRoute], now: Date,
                               maxAge: TimeInterval) -> [String: SessionRoute] {
        entries.filter { abs(now.timeIntervalSince($0.value.updatedAt)) <= maxAge }
    }

    /// Lenient decode: the document as a whole must parse as an object, but one
    /// entry missing `startedAt`/`updatedAt` (a file written by a future or past
    /// version of the format) is dropped on its own rather than failing the
    /// entire cache — per "Обработка ошибок" in the design spec. A dictionary's
    /// synthesized `Decodable` fails the whole decode on a single bad value, so
    /// decoding through `RawEntry` (whose dates are optional) is what makes the
    /// per-entry leniency possible.
    public static func decode(_ data: Data) -> [String: SessionRoute] {
        guard let raw = try? JSONDecoder().decode([String: RawEntry].self, from: data) else {
            return [:]
        }
        var result: [String: SessionRoute] = [:]
        for (id, entry) in raw {
            guard let startedAt = entry.startedAt, let updatedAt = entry.updatedAt else { continue }
            result[id] = SessionRoute(
                hostPID: entry.hostPID, hostBundlePath: entry.hostBundlePath,
                hostBundleID: entry.hostBundleID, tty: entry.tty,
                startedAt: startedAt, updatedAt: updatedAt)
        }
        return result
    }

    public static func encode(_ entries: [String: SessionRoute]) -> Data? {
        try? JSONEncoder().encode(entries)
    }

    /// Mirrors `SessionRoute` with both dates made optional, purely so a
    /// malformed entry can be detected and dropped instead of failing the
    /// whole-dictionary decode.
    private struct RawEntry: Codable {
        let hostPID: pid_t?
        let hostBundlePath: String?
        let hostBundleID: String?
        let tty: String?
        let startedAt: Date?
        let updatedAt: Date?
    }
}
