import Foundation

public enum WaitReason: Equatable, Sendable {
    case permission, question, idle
}

public enum SessionStatus: Equatable, Sendable {
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

    public init(hookEventName: String, sessionId: String, cwd: String?, message: String?,
                hostPID: pid_t? = nil, hostBundlePath: String? = nil,
                hostBundleID: String? = nil, tty: String? = nil) {
        self.hookEventName = hookEventName
        self.sessionId = sessionId
        self.cwd = cwd
        self.message = message
        self.hostPID = hostPID
        self.hostBundlePath = hostBundlePath
        self.hostBundleID = hostBundleID
        self.tty = tty
    }

    enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
        case sessionId = "session_id"
        case cwd, message
        case tty = "host_tty"
        case hostPID = "host_pid"
        case hostBundlePath = "host_bundle_path"
        case hostBundleID = "host_bundle_id"
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

    public init(sessionId: String, projectPath: String, description: String, timestamp: Date,
                isSubagent: Bool = false) {
        self.sessionId = sessionId
        self.projectPath = projectPath
        self.description = description
        self.timestamp = timestamp
        self.isSubagent = isSubagent
    }
}
