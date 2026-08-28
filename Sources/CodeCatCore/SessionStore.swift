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

    /// Если процессов claude нет и по сессии давно (>= staleAfter) не было активности — считаем её упавшей.
    public func reconcile(claudeProcessCount: Int, now: Date,
                          staleAfter: TimeInterval = 120) {
        guard claudeProcessCount == 0 else { return }
        for (id, var s) in sessions {
            let active = s.status == .working || {
                if case .waitingForYou = s.status { return true }
                return false
            }()
            if active && now.timeIntervalSince(s.lastActivity) >= staleAfter {
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
    public func applyIdleHeuristic(now: Date, threshold: TimeInterval = 60) {
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
