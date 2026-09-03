import Foundation

public enum WaitReason: Equatable, Sendable {
    case permission, question, idle
}

public enum SessionStatus: Equatable, Sendable {
    /// The session is open but its agent is doing nothing: its window or tab is
    /// alive and there is no work. This is the state `SessionStart` produces — the
    /// event means "a session appeared", not "an agent took on a task": it arrives on
    /// launch, on `--resume` and on `/clear`, at a moment when the user has not even
    /// typed their first message.
    ///
    /// `SessionStart` used to set `.working`, and an open-but-idle session lodged in
    /// the badge forever as a working agent: `Stop` never arrives for it (there was
    /// no turn), the idle heuristic is off when hooks are installed, and `reconcile`
    /// waits `longStaleAfter` (hours). Hence "no agent is running and the badge says 1".
    ///
    /// `.idle` reaches neither `aggregate` nor `badgeCount` nor `anyWorking`: what is
    /// shown and counted has to be what is actually happening.
    case idle
    case working
    case waitingForYou(WaitReason)
    case done
    case crashed

    /// The one-word label the user reads. Defined here rather than in each view
    /// because the menu-bar menu and the session list both print it, and two copies
    /// of the same five words are two translations that can drift apart.
    public var title: String {
        switch self {
        case .idle: return L10n.t("session.status.idle", "open")
        case .working: return L10n.t("session.status.working", "working")
        case .waitingForYou: return L10n.t("session.status.waiting", "waiting for you")
        case .done: return L10n.t("session.status.done", "done")
        case .crashed: return L10n.t("session.status.crashed", "stopped")
        }
    }
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

    /// PID of the `claude` process this session belongs to — the nearest ancestor of
    /// the hook with that executable name (see `ProcessTree.agent`). It is the only
    /// exact answer to "does this session still exist?": while the process lives the
    /// session lives; the moment it is gone the session is over, whatever it was
    /// doing as of the last event.
    ///
    /// Not to be confused with `hostPID`, which is the application owning the window
    /// (Terminal.app, Claude.app) — one for a dozen sessions and outliving all of
    /// them, so it says nothing about any single session's fate.
    ///
    /// `nil` for a session only the transcript watcher found: no hook ever arrived
    /// for it and there is nobody to ask, so those keep the old silence-duration
    /// heuristics.
    ///
    /// Lives in memory only and deliberately never reaches `SessionRouteCache`: after
    /// a reboot that same PID almost certainly belongs to someone else's process, and
    /// a value restored from a file would state a falsehood with the confidence of
    /// fact. After a CodeCat restart the field is refilled by this session's very
    /// next hook.
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
    /// PID of this session's `claude` process — see `Session.agentPID`.
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
    /// The activity came from a subagent's transcript
    /// (`~/.claude/projects/.../subagents/agent-*.jsonl`) rather than the session's
    /// own. A subagent carries its parent session's `sessionId`, so its work is
    /// correctly attributed to that session — but indistinguishably from the
    /// session's own work, which is what confuses someone reading the panel. This
    /// flag lets the panel tell them apart without changing who the work counts for.
    public let isSubagent: Bool

    /// The assistant entry closed the turn: `message.stop_reason == "end_turn"` — the
    /// model handed control back to the human. It is the only sign of work ending that
    /// lives in the transcript itself, and it turned out to be necessary: the `Stop`
    /// hook does not always arrive. Measured on a live machine — a session ended its
    /// turn at 01:02 (last assistant entry with `end_turn`, process idle and with no
    /// children) and the app never saw the hook, leaving the session "working" forever.
    ///
    /// Its opposite is `stop_reason == "tool_use"`: the model called a tool and the
    /// work continues. In the session that was examined there were 426 of those
    /// against 19 `end_turn`, so confusing the two is out of the question.
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
