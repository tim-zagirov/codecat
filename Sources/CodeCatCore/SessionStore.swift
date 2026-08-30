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
            upsert(id: event.sessionId, cwd: event.cwd, now: now) { s in
                s.status = .working
                s.activityDescription = "начинает работу"
            }
        case "Notification":
            let text = (event.message ?? "").lowercased()
            let reason: WaitReason = text.contains("permission") ? .permission : .question
            upsert(id: event.sessionId, cwd: event.cwd, now: now) { s in
                s.status = .waitingForYou(reason)
                s.activityDescription = "ждёт тебя"
            }
        case "Stop":
            upsert(id: event.sessionId, cwd: event.cwd, now: now) { s in
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
                sessions[id] = s
            }
        }
    }

    public func expireFinished(now: Date, ttl: TimeInterval = 600) {
        for (id, s) in sessions where s.status == .done || s.status == .crashed {
            if now.timeIntervalSince(s.lastActivity) > ttl {
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

    private func upsert(id: String, cwd: String?, now: Date,
                        _ mutate: (inout Session) -> Void) {
        var s = sessions[id] ?? Session(
            id: id,
            projectPath: cwd ?? "",
            status: .working,
            activityDescription: "",
            startedAt: now,
            lastActivity: now)
        if let cwd, !cwd.isEmpty { s.projectPath = cwd }
        s.lastActivity = now
        mutate(&s)
        sessions[id] = s
    }
}
