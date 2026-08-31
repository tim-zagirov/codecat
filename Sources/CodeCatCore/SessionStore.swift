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

    /// Что показывает кот. `.idle`-сессии сюда не входят ни в каком виде: открытая
    /// сессия, в которой никто ничего не запускал, — это `.sleeping`, спящий кот и
    /// пустой бейдж, а не «работает 1».
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
    /// Число на бейдже — это «сколько агентов прямо сейчас чем-то заняты или ждут
    /// тебя». Больше ничего.
    ///
    /// Поэтому у `.done` и `.problem` числа нет: закончившая сессия не работает, и
    /// оборвавшаяся тоже. Позы кота (доволен / тревога) сами говорят, что случилось,
    /// а сколько именно сессий в этом состоянии — видно в панели. Раньше число там
    /// было, и оно врало ровно так, как это читает человек: «ничего не запущено, а
    /// на бейдже 2» — это были две сессии, закончившие турн в последние десять минут.
    public var badgeCount: Int {
        switch aggregate {
        case .waiting(let n): return n
        case .working(let n): return n
        case .problem, .done, .sleeping: return 0
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
            // Открытая сессия без работы не повод не давать маку заснуть: держать
            // ассершен ради вкладки, в которой никто ничего не запускал, значит
            // сажать батарею за компанию с бейджем, который врал.
            case .idle, .done, .crashed: return false
            }
        }
    }

    public func apply(hook event: HookEvent, now: Date) {
        switch event.hookEventName {
        case "SessionStart":
            // `source == "compact"` — единственный случай, когда SessionStart не
            // означает появления сессии: он приходит посреди уже идущей работы, после
            // авто-компакции. Поэтому для него не трогается ни статус (сбросить
            // работающую сессию в `.idle` значило бы погасить кота ровно тогда, когда
            // агент занят), ни `startedAt` (сессия не прерывалась, и её длительность
            // не должна начинаться заново).
            //
            // Любой другой `source` — включая отсутствующий или незнакомый — считается
            // настоящим стартом и сбрасывает возможно устаревший `startedAt` из кэша
            // маршрутов (см. доккоммент `SessionRouteCache.merged`). Это безопасное
            // умолчание: SessionStart не приходит просто оттого, что перезапустили
            // CodeCat, так что случая «незнакомый source значит сохранить старое» нет.
            let isCompact = event.source == "compact"
            upsert(event: event, now: now, resetStartedAt: !isCompact) { s in
                guard !isCompact else { return }
                // Не `.working`: событие говорит «сессия появилась», а не «агент
                // взялся за работу» — см. `SessionStatus.idle`. Работа начнётся,
                // когда в транскрипте появится первая строка турна (её пишут в тот
                // же момент, когда пользователь отправляет реплику), и `apply(activity:)`
                // переведёт сессию в `.working`.
                s.status = .idle
                s.activityDescription = "открыта, ждёт задачу"
            }
        case "UserPromptSubmit":
            // Единственный сигнал «работа началась», который приходит мгновенно и
            // наверняка. Транскрипт скажет то же самое, но позже (замеры — см.
            // `HooksInstaller.events`) и подробнее: он уточнит описание, а статус
            // к тому моменту уже верный.
            upsert(event: event, now: now) { s in
                s.status = .working
                s.activityDescription = "взялся за задачу"
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
            // Сессия закончилась — маршрут для неё больше не нужен (см. спеку,
            // «Кэшируются маршруты, а не сессии»).
            routeCache?.remove(sessionId: event.sessionId)
        default:
            break // неизвестные события игнорируем
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
        // Конец турна виден прямо в транскрипте (`stop_reason == "end_turn"`), и
        // полагаться на это надёжнее, чем на хук `Stop`: тот приходит не всегда —
        // замер см. в доккомменте `TranscriptActivity.endsTurn`. Без этого сессия,
        // чей хук потерялся, оставалась «работает» навсегда.
        //
        // Турн субагента здесь не считается: субагент закончил — сессия продолжает
        // работать, разбирая его результат.
        if activity.endsTurn && !activity.isSubagent {
            s.status = .done
            s.activityDescription = "закончил"
            s.finishedAt = activity.timestamp
            s.lastActivity = activity.timestamp
            if !activity.projectPath.isEmpty { s.projectPath = activity.projectPath }
            sessions[activity.sessionId] = s
            return
        }
        s.status = .working
        // Работа субагента — это работа сессии (см. `isSubagent` на `TranscriptActivity`):
        // статус, `aggregate`, `badgeCount` и `anyWorking` не отличают её от собственной
        // работы сессии. Единственное отличие — пометка в описании, чтобы строка в панели
        // не выглядела загадочно, когда сама сессия молчит, а работу ведёт подчинённый агент.
        s.activityDescription = activity.isSubagent
            ? "субагент \(activity.description)" : activity.description
        s.lastActivity = activity.timestamp
        s.finishedAt = nil
        if !activity.projectPath.isEmpty { s.projectPath = activity.projectPath }
        sessions[activity.sessionId] = s
    }

    /// Убирает сессии, которых больше нет, двумя разными способами — точным и
    /// приблизительным, и приблизительный применяется только там, где точный
    /// недоступен.
    ///
    /// **Точный (`agentPID`).** У сессии, про которую приходил хук, известен pid её
    /// собственного процесса `claude`. Пока он жив — сессия жива, сколько бы она ни
    /// молчала: молчание идущей сессии не значит ничего (один длинный вызов
    /// инструмента, открытая вкладка, в которую человек вернётся завтра). Как только
    /// процесса не стало — сессии больше нет, и ждать нечего: работавшая помечается
    /// `.crashed` («оборвалась» — работу прервали, об этом стоит сказать), любая
    /// другая просто исчезает (её закрыли, а `SessionEnd` не дошёл — например,
    /// приложение сняли по kill).
    ///
    /// **Приблизительный (пороги тишины).** Только для сессий без `agentPID` — тех,
    /// что нашёл наблюдатель транскриптов, а хук по ним не приходил. Спросить не у
    /// кого, поэтому остаются прежние два порога: `staleAfter` (по умолчанию 120с),
    /// когда во всей системе не осталось ни одного процесса `claude`, и
    /// `longStaleAfter` (часы) — как страховка на случай, когда другие процессы
    /// `claude` живы и обнулить счётчик не выйдет. Порог в часах обязан оставаться
    /// заметно выше любого правдоподобного ожидания: сессию, которую человек
    /// действительно оставил ждать, нельзя убивать у него из-под рук.
    ///
    /// Раньше точного способа не было вовсе, и `.working`-призрак сессии, убитой
    /// по kill, висел в бейдже до четырёх часов, пока рядом жил хоть один другой
    /// `claude`.
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
                    s.activityDescription = "сессия оборвалась"
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
    ///
    /// `.idle` тоже истекает — но только у сессий без `agentPID`. Открытая сессия
    /// ничего не делает и ничего не показывает (в бейдж она не попадает), так что
    /// вечно держать её строку не за чем; а у той, чей процесс мы умеем спросить,
    /// сроком жизни распоряжается `reconcile` — она останется в панели ровно пока
    /// её `claude` жив, и по ней можно будет кликнуть, чтобы вернуться.
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
        // Пришёл вместе с событием — значит, процесс сессии жив прямо сейчас и это
        // его номер. Никогда не затираем известное значение отсутствующим: событие
        // от старой версии хука не должно лишать сессию единственного точного
        // признака жизни.
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
        // longer self-correct on a later restart. Not fixed here — see the design
        // spec's "За скобками" (recovering the route for a pre-CodeCat session is
        // explicitly out of scope, and this is the same root cause: nothing tells
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
    /// immediately and its "длится N мин" counts from when it actually began —
    /// not from the moment this process happened to notice it (`fallbackStartedAt`).
    ///
    /// Shared by both `upsert` (hook path) and `apply(activity:)` (transcript
    /// watcher path): whichever one sees a session first, the substitution is
    /// identical, per the design spec's «Подстановка» test list.
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
