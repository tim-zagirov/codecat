import Foundation

public final class SessionStore: ObservableObject {
    @Published public private(set) var sessions: [String: Session] = [:]

    /// Optional persisted route memory — see `SessionRouteCache`. `nil` by
    /// default so every existing call site (and every existing test) that
    /// constructs a bare `SessionStore()` keeps working unchanged; a route
    /// cache is something a caller opts into, not something the store requires.
    private let routeCache: SessionRouteCache?

    public init(routeCache: SessionRouteCache? = nil) {
        self.routeCache = routeCache
    }

    public var ordered: [Session] {
        sessions.values.sorted { $0.startedAt < $1.startedAt }
    }

    /// What the cat shows. `.idle` sessions do not enter into this at all: an open
    /// session in which nobody has started anything is `.sleeping` — a sleeping cat
    /// and an empty badge, not "working: 1".
    public var aggregate: AggregateStatus {
        let all = sessions.values
        let waiting = all.filter {
            if case .waitingForYou = $0.status { return true }
            return false
        }.count
        if waiting > 0 { return .waiting(waiting) }
        if all.contains(where: { $0.status == .crashed }) { return .problem }
        let working = all.filter { $0.status == .working }.count
        if working > 0 { return .working(working) }
        if all.contains(where: { $0.status == .done }) { return .done }
        return .sleeping
    }

    /// How many sessions are in the state the mascot is *currently displaying* — the
    /// number that belongs next to the badge's colour, because they must describe the
    /// same population and previously didn't.
    ///
    /// The bug this fixes: `OverlayPanel` used to pass `ordered.count` — every tracked
    /// session, including `.done`/`.crashed` ones still lingering inside
    /// `expireFinished`'s TTL (up to 600s) — as the badge's number, while the badge's
    /// *colour* came from `aggregate`, which only counts the sessions in the state
    /// being shown. Two agents genuinely working could badge "5" because three
    /// finished sessions hadn't expired yet. The design spec calls it a badge
    /// carrying the number of *active* sessions — not the number of everything this
    /// process still
    /// happens to remember.
    ///
    /// Deliberately derived from `aggregate` rather than recomputing "which state is
    /// the mascot in" a second time: two places independently deciding that question
    /// is exactly how the number and the colour drifted apart in the first place.
    /// The number on the badge means "how many agents are busy or waiting for you
    /// right now". Nothing else.
    ///
    /// That is why `.done` and `.problem` carry no number: a finished session is not
    /// working, and neither is one that died. The cat's poses (content / alarmed)
    /// already say what happened, and how many sessions are in that state is visible
    /// in the panel. The number used to be there, and it lied in precisely the way a
    /// person reads it: "nothing is running, and the badge says 2" meant two sessions
    /// had finished their turn within the last ten minutes.
    public var badgeCount: Int {
        switch aggregate {
        case .waiting(let n): return n
        case .working(let n): return n
        case .problem, .done, .sleeping: return 0
        }
    }

    /// Whether there are any tracked sessions at all, regardless of what they are doing.
    ///
    /// It answers exactly the question "are there sessions", and that is the whole
    /// point: `aggregate` answers a different one — "what does the cat show". Once
    /// `.idle` existed the two questions diverged: an open but idle session yields
    /// `.sleeping` even though the session exists. The "hide the island when nothing
    /// is running" setting read `aggregate` and so took the island off screen while
    /// sessions were sitting happily in the panel.
    public var hasSessions: Bool { !sessions.isEmpty }

    /// True when at least one session's *own* status counts as work in progress —
    /// unlike `aggregate`, which is a display-priority value (waiting outranks working
    /// so the UI surfaces the thing that needs the user's attention) and therefore must
    /// never drive power policy: with one session waiting and another still working,
    /// `aggregate` reports `.waiting`, which would wrongly tell `PowerManager` nothing
    /// is working and let the Mac idle-sleep mid-run.
    ///
    /// `.waitingForYou(.idle)` counts as working: it is a heuristic guess (no activity
    /// for a while in fallback mode without hooks installed), not a real signal that the
    /// user's input is needed — a long single tool call looks identical. Real
    /// `.waitingForYou(.permission)` / `.waitingForYou(.question)` come from an actual
    /// `Notification` hook firing and do not count as working.
    public var anyWorking: Bool {
        sessions.values.contains { session in
            switch session.status {
            case .working: return true
            case .waitingForYou(.idle): return true
            case .waitingForYou: return false
            // An open session with no work is no reason to keep the Mac awake: holding
            // an assertion for a tab nobody has started anything in drains the battery
            // for the same reason the badge used to lie.
            case .idle, .done, .crashed: return false
            }
        }
    }

    public func apply(hook event: HookEvent, now: Date) {
        switch event.hookEventName {
        case "SessionStart":
            // `source == "compact"` is the one case where SessionStart does not mean a
            // session appeared: it arrives in the middle of ongoing work, after an
            // auto-compaction. So it touches neither the status (resetting a working
            // session to `.idle` would put the cat to sleep exactly while the agent is
            // busy) nor `startedAt` (the session never stopped, and its duration must
            // not start over).
            //
            // Any other `source` — including a missing or unfamiliar one — counts as a
            // real start and clears the possibly stale `startedAt` from the route cache
            // (see `SessionRouteCache.merged`). That is the safe default: SessionStart
            // does not arrive merely because CodeCat was restarted, so there is no case
            // where an unknown source ought to mean "keep the old value".
            let isCompact = event.source == "compact"
            upsert(event: event, now: now, resetStartedAt: !isCompact) { s in
                guard !isCompact else { return }
                // Not `.working`: the event says "a session appeared", not "an agent
                // started working" — see `SessionStatus.idle`. Work begins when the
                // first line of a turn shows up in the transcript (written at the same
                // moment the user sends a message), and `apply(activity:)` moves the
                // session to `.working`.
                s.status = .idle
                s.activityDescription = L10n.t("activity.session.opened", "open, waiting for a task")
            }
        case "UserPromptSubmit":
            // The one "work has started" signal that arrives instantly and reliably.
            // The transcript says the same thing later (measurements in
            // `HooksInstaller.events`) and in more detail: it refines the description,
            // by which time the status is already right.
            upsert(event: event, now: now) { s in
                s.status = .working
                s.activityDescription = L10n.t("activity.session.started", "started on the task")
            }
        case "Notification":
            let text = (event.message ?? "").lowercased()
            let reason: WaitReason = text.contains("permission") ? .permission : .question
            upsert(event: event, now: now) { s in
                s.status = .waitingForYou(reason)
                s.activityDescription = L10n.t("activity.waiting", "waiting for you")
            }
        case "Stop":
            upsert(event: event, now: now) { s in
                s.status = .done
                s.activityDescription = L10n.t("activity.done", "finished the task")
            }
        case "SessionEnd":
            sessions.removeValue(forKey: event.sessionId)
            // The session is over, so its route is no longer needed — the cache holds
            // routes, not sessions.
            routeCache?.remove(sessionId: event.sessionId)
        default:
            break // unknown events are ignored
        }
    }

    public func apply(activity: TranscriptActivity) {
        let isNew = sessions[activity.sessionId] == nil
        var s = sessions[activity.sessionId] ?? newSession(
            id: activity.sessionId, projectPath: activity.projectPath,
            activityDescription: activity.description, fallbackStartedAt: activity.timestamp,
            lastActivity: activity.timestamp)
        guard activity.timestamp > s.lastActivity || isNew else { return }
        guard s.status != .crashed else { return }
        // The end of a turn is visible in the transcript itself (`stop_reason ==
        // "end_turn"`), and relying on that is safer than relying on the `Stop` hook,
        // which does not always arrive — measurements are in `TranscriptActivity.endsTurn`.
        // Without this, a session whose hook went missing stayed "working" forever.
        //
        // A subagent's turn does not count here: the subagent finished, and the
        // session carries on working through its result.
        if activity.endsTurn && !activity.isSubagent {
            s.status = .done
            s.activityDescription = L10n.t("activity.done", "finished the task")
            s.finishedAt = activity.timestamp
            s.lastActivity = activity.timestamp
            if !activity.projectPath.isEmpty { s.projectPath = activity.projectPath }
            sessions[activity.sessionId] = s
            return
        }
        s.status = .working
        // A subagent's work is the session's work (see `isSubagent` on
        // `TranscriptActivity`): status, `aggregate`, `badgeCount` and `anyWorking`
        // do not tell them apart. The only difference is a note in the description, so
        // the panel row is not mystifying when the session itself is silent and a
        // subordinate agent is doing the work.
        s.activityDescription = activity.isSubagent
            ? L10n.f("activity.subagent", "subagent %@", activity.description)
            : activity.description
        s.lastActivity = activity.timestamp
        s.finishedAt = nil
        if !activity.projectPath.isEmpty { s.projectPath = activity.projectPath }
        sessions[activity.sessionId] = s
    }

    /// Removes sessions that no longer exist, two different ways — an exact one and
    /// an approximate one, with the approximate one used only where the exact one is
    /// unavailable.
    ///
    /// **Exact (`agentPID`).** For a session a hook arrived for, the pid of its own
    /// `claude` process is known. While that process lives the session lives, however
    /// long it stays silent: silence in a running session means nothing (one long
    /// tool call, an open tab someone will return to tomorrow). The moment the process
    /// is gone the session is gone and there is nothing to wait for — one that was
    /// working is marked `.crashed` (its work was cut off, which is worth saying), and
    /// any other simply disappears (it was closed and `SessionEnd` never arrived —
    /// the app was killed, say).
    ///
    /// **Approximate (silence thresholds).** Only for sessions with no `agentPID` —
    /// the ones the transcript watcher found and no hook ever reported. There is
    /// nobody to ask, so the two old thresholds remain: `staleAfter` (120s by default)
    /// when no `claude` process is left anywhere on the system, and `longStaleAfter`
    /// (hours) as a backstop for when other `claude` processes are alive and the
    /// counter cannot be zeroed. The hours-long threshold has to stay well above any
    /// plausible wait: a session someone genuinely left waiting must not be killed out
    /// from under them.
    ///
    /// There used to be no exact method at all, and a `.working` ghost of a session
    /// killed outright would hang in the badge for up to four hours as long as one
    /// other `claude` was alive nearby.
    public func reconcile(claudeProcessCount: Int, now: Date,
                          staleAfter: TimeInterval = 120,
                          longStaleAfter: TimeInterval = 4 * 60 * 60,
                          isAgentAlive: (pid_t) -> Bool = { ProcessScanner.isProcess($0) }) {
        let threshold = claudeProcessCount == 0 ? staleAfter : longStaleAfter
        for (id, var s) in sessions {
            if let agentPID = s.agentPID {
                guard !isAgentAlive(agentPID) else { continue }
                if s.status == .working {
                    s.status = .crashed
                    s.activityDescription = L10n.t("activity.session.stopped", "the session stopped")
                    s.finishedAt = now
                    sessions[id] = s
                } else {
                    sessions.removeValue(forKey: id)
                    routeCache?.remove(sessionId: id)
                }
                continue
            }
            let active = s.status == .working || {
                if case .waitingForYou = s.status { return true }
                return false
            }()
            if active && now.timeIntervalSince(s.lastActivity) >= threshold {
                s.status = .crashed
                s.activityDescription = L10n.t("activity.session.stopped", "the session stopped")
                s.finishedAt = now
                sessions[id] = s
            }
        }
    }

    /// Removes sessions that have sat in a terminal state (`.done`/`.crashed`) for
    /// longer than `ttl`, measured from `finishedAt` — when the session *finished* —
    /// not from `lastActivity` — when it last did something. A session reconciled to
    /// `.crashed` long after it went quiet (the long-staleness path in `reconcile`)
    /// must still get the full `ttl` window of visibility from the moment it was marked
    /// crashed, otherwise it can be deleted in the same tick it first appears as a
    /// problem. Falls back to `lastActivity` only for the (currently unreachable)
    /// case of a terminal session with no `finishedAt`.
    ///
    /// `.idle` expires too — but only for sessions with no `agentPID`. An open session
    /// does nothing and shows nothing (it never reaches the badge), so there is no
    /// reason to keep its row forever; for one whose process can be asked, `reconcile`
    /// governs its lifetime — it stays in the panel exactly as long as its `claude`
    /// lives, and stays clickable so you can go back to it.
    public func expireFinished(now: Date, ttl: TimeInterval = 600) {
        for (id, s) in sessions {
            switch s.status {
            case .done, .crashed:
                let finishedReference = s.finishedAt ?? s.lastActivity
                if now.timeIntervalSince(finishedReference) > ttl {
                    sessions.removeValue(forKey: id)
                }
            case .idle:
                if s.agentPID == nil, now.timeIntervalSince(s.lastActivity) > ttl {
                    sessions.removeValue(forKey: id)
                }
            case .working, .waitingForYou:
                break
            }
        }
    }

    /// Fallback with no hooks: a quiet working session is marked "waiting for you (idle)".
    ///
    /// This is a guess, not a real signal — a transcript is silent during any single
    /// long tool call (Claude Code writes the `tool_use` entry, then nothing until the
    /// tool returns), so the threshold must sit well above a plausible tool/build
    /// duration. `anyWorking` (see above) treats the resulting `.idle` wait as work in
    /// progress specifically so this heuristic firing never drops the sleep-prevention
    /// assertion; the threshold is still kept high so the UI itself doesn't cry wolf
    /// (badge, sound, away-log entry) over an ordinary long build.
    public func applyIdleHeuristic(now: Date, threshold: TimeInterval = 5 * 60) {
        for (id, var s) in sessions where s.status == .working {
            if now.timeIntervalSince(s.lastActivity) >= threshold {
                s.status = .waitingForYou(.idle)
                s.activityDescription = L10n.t("activity.waiting.maybe", "looks like it is waiting for you")
                sessions[id] = s
            }
        }
    }

    private func upsert(event: HookEvent, now: Date, resetStartedAt: Bool = false,
                        _ mutate: (inout Session) -> Void) {
        var s = sessions[event.sessionId] ?? newSession(
            id: event.sessionId, projectPath: event.cwd ?? "",
            activityDescription: "", fallbackStartedAt: now, lastActivity: now)
        // Assigned unconditionally, whether `s` just came from `newSession` (its
        // `fallbackStartedAt` is already `now`, so this is a no-op there) or was
        // already sitting in `sessions` — a lingering `.done`/`.crashed` session
        // (still visible inside `expireFinished`'s TTL, or `reconcile`'s longer one)
        // is reachable without any CodeCat restart, and `newSession` never runs for
        // it, so this used to be the only place `resetStartedAt` could ever apply
        // for such a session — and it never did. See SessionRouteCache.merged's doc
        // comment for why a genuine SessionStart presumes the old value stale.
        if resetStartedAt { s.startedAt = now }
        if let cwd = event.cwd, !cwd.isEmpty { s.projectPath = cwd }
        s.lastActivity = now
        // Only ever fill the route in, never clear it: a `Notification` from an older
        // hook binary, or any event that lost its enrichment, must not disable the
        // jump for a session whose route is already known.
        //
        // `hostPID`/`hostBundlePath`/`hostBundleID` describe one host reading and are
        // therefore replaced **as a unit** whenever a fresh `hostPID` arrives, never
        // field by field — mirroring `SessionRouteCache.merged`'s rule. The hook
        // derives pid and path together from `ProcessTree.host` but looks the bundle
        // id up separately (`Bundle(path:)?.bundleIdentifier`, which can independently
        // return nil), so a fresh pid/path with no bundle id must come out as "unknown
        // bundle id for the new host", not as the *previous* host's bundle id — that
        // would describe a route naming two different hosts at once and route the
        // jump to the wrong application.
        // If it came with the event, the session's process is alive right now and this
        // is its number. Never overwrite a known value with a missing one: an event
        // from an older hook build must not strip a session of the one exact sign of
        // life it has.
        if let agentPID = event.agentPID { s.agentPID = agentPID }
        if let pid = event.hostPID {
            s.hostPID = pid
            s.hostBundlePath = nonEmpty(event.hostBundlePath)
            s.hostBundleID = nonEmpty(event.hostBundleID)
        }
        if let tty = event.tty, !tty.isEmpty { s.tty = tty }
        mutate(&s)
        switch s.status {
        case .done, .crashed:
            if s.finishedAt == nil { s.finishedAt = now }
        case .idle, .working, .waitingForYou:
            s.finishedAt = nil
        }
        sessions[event.sessionId] = s

        // Route fields only ever arrive from a hook — record them into the cache
        // whenever this event carried any, so a future restart can restore them
        // for this session. `routeCache.record` does its own never-clobber merge
        // against whatever it already has, so a partial payload here (some
        // fields present, some not) still cannot blank out a field the cache
        // already knows.
        //
        // Known limitation: `s.startedAt` passed below can be a value `newSession`
        // set from `fallbackStartedAt` — the moment the transcript watcher first
        // discovered this session, not its real start — when no cached route
        // existed yet and this is the first hook event for it. Before this cache
        // existed, that guess was recomputed fresh on every launch; now `merged`
        // freezes whatever gets recorded first, so this particular guess can no
        // longer self-correct on a later restart. Not fixed here — recovering the route
        // for a session that started before CodeCat is explicitly out of scope, and
        // this is the same root cause: nothing tells
        // us the watcher's discovery time isn't the true start).
        // Also record unconditionally when `resetStartedAt` is true, even if this
        // particular event carries no route fields at all — a `SessionStart` for a
        // non-interactive `claude -p` under tmux/ssh/CI (no `.app` ancestor, no tty)
        // still resets the in-memory `startedAt` above, and skipping the cache write
        // here would leave its persisted entry with the stale `startedAt`/`updatedAt`,
        // reintroducing the stale duration on a restart within the cache's 7-day
        // window. Safe because `record`'s merge is never-clobbering — a payload with
        // no route fields cannot blank out a field the cache already has.
        if resetStartedAt || event.hostPID != nil || event.hostBundlePath != nil
            || event.hostBundleID != nil || event.tty != nil {
            // `resetStartedAt` must also reach the persisted entry, not just the
            // in-memory `Session` built above — otherwise a *second* silent crash
            // (no SessionEnd) followed by another resume within the cache's 7-day
            // window would restore the very value we just corrected.
            routeCache?.record(
                sessionId: event.sessionId, hostPID: s.hostPID, hostBundlePath: s.hostBundlePath,
                hostBundleID: s.hostBundleID, tty: s.tty, startedAt: s.startedAt, now: now,
                resetStartedAt: resetStartedAt)
        }
    }

    /// Builds a brand-new `Session` for an id neither `sessions` nor (via the
    /// caller passing it through) anything else yet knows about, consulting the
    /// route cache first: a cached `SessionRoute` for this id supplies the
    /// missing `hostPID`/`hostBundlePath`/`hostBundleID`/`tty` *and* the real
    /// `startedAt`, so a session restored after a CodeCat restart is clickable
    /// immediately and its "running for N min" counts from when it actually began —
    /// not from the moment this process happened to notice it (`fallbackStartedAt`).
    ///
    /// Shared by both `upsert` (hook path) and `apply(activity:)` (transcript
    /// watcher path): whichever one sees a session first, the substitution is
    /// identical.
    ///
    /// Takes no `resetStartedAt` flag: `upsert` is the only caller that ever needs
    /// one (a genuine `SessionStart`, see `apply(hook:)`), and it already passes
    /// `fallbackStartedAt: now` for that path — a cache hit's `startedAt` would
    /// simply be overwritten again once `upsert` applies its own reset immediately
    /// after this returns. Keeping the reset in exactly one place (`upsert`) means
    /// it now also covers a session that was already sitting in `sessions` (where
    /// this function never runs at all), instead of two places that had to agree
    /// and didn't. `apply(activity:)` never had a reset signal to give it either —
    /// a session the transcript watcher discovers on its own must keep inheriting
    /// the cache's `startedAt` exactly as before: that is the core case this cache
    /// exists for (a bare CodeCat restart fires no `SessionStart` at all).
    ///
    /// Known limitation, not fixed here: for a session first seen by the
    /// transcript watcher with no cached route at all, `startedAt` is the
    /// discovery time (`fallbackStartedAt`), and once persisted by the next
    /// hook event, `merged` freezes that value for good — it can no longer be
    /// corrected retroactively the way a stale value now can on `SessionStart`.
    private func newSession(id: String, projectPath: String, activityDescription: String,
                            fallbackStartedAt: Date, lastActivity: Date) -> Session {
        let cached = routeCache?.route(for: id)
        let startedAt = cached?.startedAt ?? fallbackStartedAt
        var s = Session(
            id: id,
            projectPath: projectPath,
            status: .working,
            activityDescription: activityDescription,
            startedAt: startedAt,
            lastActivity: lastActivity)
        if let cached {
            s.hostPID = cached.hostPID
            s.hostBundlePath = cached.hostBundlePath
            s.hostBundleID = cached.hostBundleID
            s.tty = cached.tty
        }
        return s
    }
}

/// Empty string reads as absent for route fields — an unreadable Info.plist, a
/// process with no controlling terminal, both report `""` rather than `nil`.
/// Mirrors `SessionRouteCache.nonEmpty`, kept here so `SessionStore` doesn't need
/// to reach into that type's private helper for the same one-line rule.
private func nonEmpty(_ s: String?) -> String? {
    guard let s, !s.isEmpty else { return nil }
    return s
}
