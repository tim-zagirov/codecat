import Foundation

public final class SessionStore: ObservableObject {
    @Published public private(set) var sessions: [String: Session] = [:]

    public init() {}

    public var ordered: [Session] {
        sessions.values.sorted { $0.startedAt < $1.startedAt }
    }

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
    /// finished sessions hadn't expired yet. The design spec calls the badge
    /// «бейдж с числом активных сессий» (`docs/superpowers/specs/2026-08-28-codecat-design.md:83`)
    /// — the number of *active* sessions, not of everything this process still
    /// happens to remember.
    ///
    /// Deliberately derived from `aggregate` rather than recomputing "which state is
    /// the mascot in" a second time: two places independently deciding that question
    /// is exactly how the number and the colour drifted apart in the first place.
    public var badgeCount: Int {
        switch aggregate {
        case .waiting(let n): return n
        case .working(let n): return n
        case .problem: return sessions.values.filter { $0.status == .crashed }.count
        case .done: return sessions.values.filter { $0.status == .done }.count
        case .sleeping: return 0
        }
    }

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
            case .done, .crashed: return false
            }
        }
    }

    public func apply(hook event: HookEvent, now: Date) {
        switch event.hookEventName {
        case "SessionStart":
            upsert(event: event, now: now) { s in
                s.status = .working
                s.activityDescription = "начинает работу"
            }
        case "Notification":
            let text = (event.message ?? "").lowercased()
            let reason: WaitReason = text.contains("permission") ? .permission : .question
            upsert(event: event, now: now) { s in
                s.status = .waitingForYou(reason)
                s.activityDescription = "ждёт тебя"
            }
        case "Stop":
            upsert(event: event, now: now) { s in
                s.status = .done
                s.activityDescription = "закончил"
            }
        case "SessionEnd":
            sessions.removeValue(forKey: event.sessionId)
        default:
            break // неизвестные события игнорируем
        }
    }

    public func apply(activity: TranscriptActivity) {
        var s = sessions[activity.sessionId] ?? Session(
            id: activity.sessionId,
            projectPath: activity.projectPath,
            status: .working,
            activityDescription: activity.description,
            startedAt: activity.timestamp,
            lastActivity: activity.timestamp)
        guard activity.timestamp > s.lastActivity || sessions[activity.sessionId] == nil else { return }
        guard s.status != .crashed else { return }
        s.status = .working
        s.activityDescription = activity.description
        s.lastActivity = activity.timestamp
        s.finishedAt = nil
        if !activity.projectPath.isEmpty { s.projectPath = activity.projectPath }
        sessions[activity.sessionId] = s
    }

    /// Marks a session `.crashed` once it has been `.working`/`.waitingForYou` with no
    /// activity for too long, via two independent checks:
    ///
    /// - Fast path: if `pgrep -x claude` finds zero processes at all, any active session
    ///   quiet for `staleAfter` (default 120s) is almost certainly dead — its process
    ///   exited without ever sending `SessionEnd` (e.g. the terminal was closed).
    /// - Slow path: regardless of the global process count, any active session quiet for
    ///   `longStaleAfter` (default: hours, not minutes) is also marked crashed. This
    ///   covers a SIGKILL'd session while *other* `claude` processes are still alive:
    ///   `pgrep -x claude` stays nonzero, so the fast path never fires, and without this
    ///   the dead session would wait forever — permanently red-badging the UI, and (via
    ///   `anyWorking`) holding the sleep-prevention assertion forever if it died mid-work.
    ///   `longStaleAfter` must stay well above any plausible legitimate idle wait, since a
    ///   session a user genuinely left waiting must not be killed out from under them.
    public func reconcile(claudeProcessCount: Int, now: Date,
                          staleAfter: TimeInterval = 120,
                          longStaleAfter: TimeInterval = 4 * 60 * 60) {
        let threshold = claudeProcessCount == 0 ? staleAfter : longStaleAfter
        for (id, var s) in sessions {
            let active = s.status == .working || {
                if case .waitingForYou = s.status { return true }
                return false
            }()
            if active && now.timeIntervalSince(s.lastActivity) >= threshold {
                s.status = .crashed
                s.activityDescription = "сессия оборвалась"
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
    public func expireFinished(now: Date, ttl: TimeInterval = 600) {
        for (id, s) in sessions where s.status == .done || s.status == .crashed {
            let finishedReference = s.finishedAt ?? s.lastActivity
            if now.timeIntervalSince(finishedReference) > ttl {
                sessions.removeValue(forKey: id)
            }
        }
    }

    /// Fallback без хуков: тихая работающая сессия помечается как «ждёт тебя (idle)».
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
                s.activityDescription = "похоже, ждёт тебя"
                sessions[id] = s
            }
        }
    }

    private func upsert(event: HookEvent, now: Date,
                        _ mutate: (inout Session) -> Void) {
        var s = sessions[event.sessionId] ?? Session(
            id: event.sessionId,
            projectPath: event.cwd ?? "",
            status: .working,
            activityDescription: "",
            startedAt: now,
            lastActivity: now)
        if let cwd = event.cwd, !cwd.isEmpty { s.projectPath = cwd }
        s.lastActivity = now
        // Only ever fill the route in, never clear it: a `Notification` from an older
        // hook binary, or any event that lost its enrichment, must not disable the
        // jump for a session whose route is already known.
        if let pid = event.hostPID { s.hostPID = pid }
        if let path = event.hostBundlePath, !path.isEmpty { s.hostBundlePath = path }
        if let id = event.hostBundleID, !id.isEmpty { s.hostBundleID = id }
        if let tty = event.tty, !tty.isEmpty { s.tty = tty }
        mutate(&s)
        switch s.status {
        case .done, .crashed:
            if s.finishedAt == nil { s.finishedAt = now }
        case .working, .waitingForYou:
            s.finishedAt = nil
        }
        sessions[event.sessionId] = s
    }
}
