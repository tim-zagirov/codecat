import Foundation

public enum WaitReason: Equatable, Sendable {
    case permission, question, idle
}

public enum SessionStatus: Equatable, Sendable {
    /// Сессия открыта, но агент в ней ничего не делает: её окно/вкладка живы, а
    /// работы нет. Именно это состояние даёт `SessionStart` — событие означает
    /// «сессия появилась», а не «агент взялся за задачу»: оно приходит и при
    /// запуске, и при `--resume`, и при `/clear`, то есть в момент, когда
    /// пользователь ещё даже не написал первую реплику.
    ///
    /// Раньше `SessionStart` ставил `.working`, и открытая-но-простаивающая сессия
    /// навсегда оседала в бейдже как работающий агент: `Stop` для неё не приходит
    /// (турна не было), эвристика простоя выключена при установленных хуках, а
    /// `reconcile` ждёт `longStaleAfter` (часы). Отсюда «ни один агент не запущен,
    /// а на бейдже 1».
    ///
    /// `.idle` не попадает ни в `aggregate`, ни в `badgeCount`, ни в `anyWorking`:
    /// показывать и считать нужно то, что реально происходит.
    case idle
    case working
    case waitingForYou(WaitReason)
    case done
    case crashed
}

public struct Session: Identifiable, Equatable, Sendable {
    public let id: String
    public var projectPath: String
    public var status: SessionStatus
    public var activityDescription: String
    public var startedAt: Date
    public var lastActivity: Date
    /// When this session most recently entered a terminal state (`.done` or `.crashed`).
    /// `nil` while the session is active. `expireFinished` measures its TTL from this,
    /// not from `lastActivity` — the two answer different questions: `lastActivity` is
    /// "when did this session last do something", `finishedAt` is "when did it finish".
    /// Conflating them let a session that went quiet long before it was reconciled to
    /// `.crashed` (the long-staleness path) look already-expired the instant it crashed,
    /// so it was deleted before ever being shown as a problem.
    public var finishedAt: Date? = nil

    /// PID процесса `claude`, которому принадлежит эта сессия — ближайший предок
    /// хука с таким именем исполняемого файла (см. `ProcessTree.agent`). Это
    /// единственный точный ответ на вопрос «сессия ещё существует?»: пока процесс
    /// жив, сессия жива; как только он исчез — сессия закончилась, чем бы она ни
    /// была занята по последнему известному событию.
    ///
    /// Не путать с `hostPID`: тот — приложение-владелец окна (Terminal.app,
    /// Claude.app), одно на десяток сессий и живущее дольше любой из них; по нему
    /// нельзя судить о судьбе конкретной сессии.
    ///
    /// `nil` у сессии, которую нашёл только наблюдатель транскриптов: хук по ней
    /// не приходил, спросить не у кого — для таких остаются прежние эвристики по
    /// времени тишины.
    ///
    /// Живёт только в памяти и намеренно не попадает в `SessionRouteCache`:
    /// после перезагрузки машины тот же номер PID почти наверняка занят чужим
    /// процессом, и восстановленное из файла значение сообщало бы неправду с
    /// уверенностью факта. После рестарта CodeCat поле заполнится заново первым
    /// же хуком этой сессии.
    public var agentPID: pid_t? = nil

    /// Where this session lives, as recorded by `codecat-hook`. Nil for a session
    /// the transcript watcher discovered on its own — it has no route.
    public var hostPID: pid_t? = nil
    public var hostBundlePath: String? = nil
    public var hostBundleID: String? = nil
    public var tty: String? = nil

    public var projectName: String {
        (projectPath as NSString).lastPathComponent
    }
}

public enum AggregateStatus: Equatable, Sendable {
    case sleeping
    case working(Int)
    case waiting(Int)
    case done
    case problem
}

public struct HookEvent: Codable, Equatable, Sendable {
    public let hookEventName: String
    public let sessionId: String
    public let cwd: String?
    public let message: String?
    /// Route to the session, added by `codecat-hook` (see `HookPayload`). All
    /// optional: an older hook binary, or a payload that failed to parse, sends none
    /// of them and the event must still be accepted.
    public let hostPID: pid_t?
    public let hostBundlePath: String?
    public let hostBundleID: String?
    public let tty: String?
    /// PID процесса `claude` этой сессии — см. `Session.agentPID`.
    public let agentPID: pid_t?
    /// Claude Code's own field on `SessionStart`, documented values `startup`,
    /// `resume`, `clear`, `compact`. Confirmed by capturing a real payload from a
    /// live `claude -p`/`claude --resume` run against the hook socket — see
    /// route-cache-report.md. `nil` for every other event, and for a `SessionStart`
    /// sent by an older Claude Code version that doesn't send it.
    public let source: String?

    public init(hookEventName: String, sessionId: String, cwd: String?, message: String?,
                hostPID: pid_t? = nil, hostBundlePath: String? = nil,
                hostBundleID: String? = nil, tty: String? = nil, source: String? = nil,
                agentPID: pid_t? = nil) {
        self.hookEventName = hookEventName
        self.sessionId = sessionId
        self.cwd = cwd
        self.message = message
        self.hostPID = hostPID
        self.hostBundlePath = hostBundlePath
        self.hostBundleID = hostBundleID
        self.tty = tty
        self.source = source
        self.agentPID = agentPID
    }

    enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
        case sessionId = "session_id"
        case cwd, message, source
        case tty = "host_tty"
        case hostPID = "host_pid"
        case hostBundlePath = "host_bundle_path"
        case hostBundleID = "host_bundle_id"
        case agentPID = "agent_pid"
    }
}

public struct TranscriptActivity: Equatable, Sendable {
    public let sessionId: String
    public let projectPath: String
    public let description: String
    public let timestamp: Date
    /// Активность пришла из транскрипта субагента (`~/.claude/projects/.../subagents/agent-*.jsonl`),
    /// а не из транскрипта самой сессии. Субагент несёт `sessionId` родительской сессии,
    /// поэтому его работа корректно приписывается ей же — но неотличимо от собственной
    /// работы сессии, что и путает пользователя, глядя на панель. Этот флаг даёт панели
    /// способ отличить одно от другого, ничего не меняя в том, кому активность засчитана.
    public let isSubagent: Bool

    /// Запись ассистента закрыла турн: `message.stop_reason == "end_turn"` — модель
    /// вернула управление человеку. Это единственный признак конца работы, который
    /// живёт в самом транскрипте, и он оказался нужен: хук `Stop` приходит не всегда.
    /// Замерено на живой машине — сессия закончила турн в 01:02 (последняя запись
    /// ассистента с `end_turn`, процесс без нагрузки и без детей), а хука приложение
    /// так и не увидело, и сессия навсегда осталась «работает».
    ///
    /// Противоположность — `stop_reason == "tool_use"`: модель вызвала инструмент,
    /// работа продолжается. В разобранной сессии таких записей 426 против 19
    /// `end_turn`, так что путать их нельзя ни в коем случае.
    public let endsTurn: Bool

    public init(sessionId: String, projectPath: String, description: String, timestamp: Date,
                isSubagent: Bool = false, endsTurn: Bool = false) {
        self.sessionId = sessionId
        self.projectPath = projectPath
        self.description = description
        self.timestamp = timestamp
        self.isSubagent = isSubagent
        self.endsTurn = endsTurn
    }
}
