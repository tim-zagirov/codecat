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

    public init(hookEventName: String, sessionId: String, cwd: String?, message: String?) {
        self.hookEventName = hookEventName
        self.sessionId = sessionId
        self.cwd = cwd
        self.message = message
    }

    enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
        case sessionId = "session_id"
        case cwd, message
    }
}

public struct TranscriptActivity: Equatable, Sendable {
    public let sessionId: String
    public let projectPath: String
    public let description: String
    public let timestamp: Date

    public init(sessionId: String, projectPath: String, description: String, timestamp: Date) {
        self.sessionId = sessionId
        self.projectPath = projectPath
        self.description = description
        self.timestamp = timestamp
    }
}
