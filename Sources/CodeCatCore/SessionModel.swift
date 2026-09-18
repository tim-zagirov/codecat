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
        case .crashed: return L10n.t("session.status.crashed", "ended")
        }
    }

    /// The colour a session's own dot is drawn in — the same vocabulary the island
    /// counter and the floating badge use, so a dot on the island and a dot in a row
    /// can never mean two different things.
    public var tone: MascotTone {
        switch self {
        case .idle: return .sleeping
        case .working: return .working
        case .waitingForYou: return .waiting
        case .done: return .done
        case .crashed: return .problem
        }
    }
}

/// One item of the agent's own task list, as it wrote it with `TodoWrite` or
/// `TaskCreate`. The list is the only statement of a plan that exists anywhere in
/// the transcript; the tool in hand ("editing api.ts") says what the agent is
/// touching, this says what it is *for*.
public struct TaskStep: Equatable, Sendable, Identifiable {
    public enum Status: String, Equatable, Sendable { case pending, inProgress, completed }
    /// `TodoWrite` lists have no ids, so the index is the id — they are replaced
    /// whole on every call and only need to be stable within one. `TaskCreate`
    /// tasks are numbered by Claude Code ("Task #3") and that number is the id.
    public let id: String
    public var title: String
    /// `TodoWrite`'s present-continuous form ("Writing the parser"), the better line
    /// for a step that is happening right now. `TaskCreate` sends none.
    public var activeForm: String?
    public var status: Status

    public init(id: String, title: String, activeForm: String? = nil, status: Status) {
        self.id = id; self.title = title; self.activeForm = activeForm; self.status = status
    }

    /// The line the row shows for this step.
    public var displayTitle: String {
        if let activeForm, !activeForm.isEmpty { return activeForm }
        return title
    }
}

/// A change to a session's task list, read off one transcript line. See
/// `TranscriptParser` for where each case comes from.
public enum StepsUpdate: Equatable, Sendable {
    case replaceAll([TaskStep])
    case create(id: String, title: String)
    case update(id: String, status: TaskStep.Status)
    case remove(id: String)
}

/// Something the agent's final message pointed at: a dev server, a pull request, a
/// file it wrote. The chip under a finished session.
public struct HandoffLink: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case localhost, pullRequest, github, figma, artifact, web, file, folder
    }
    /// The target as written, so two mentions of the same link are one chip.
    public let id: String
    public let kind: Kind
    public let title: String
    public let target: URL

    public init(kind: Kind, title: String, target: URL) {
        self.id = target.absoluteString; self.kind = kind; self.title = title; self.target = target
    }
}

/// What a finished turn hands the user: the first line of the agent's last message
/// and the links in it. Nil on a session whose last turn said nothing worth a chip.
public struct Handoff: Equatable, Sendable {
    public let summary: String?
    public let links: [HandoffLink]
    public init(summary: String?, links: [HandoffLink]) {
        self.summary = summary; self.links = links
    }
}

public struct Session: Identifiable, Equatable, Sendable {
    public let id: String
    public var projectPath: String
    public var status: SessionStatus
    public var activityDescription: String
    /// What the user asked this session for, as one line — the answer to "what is
    /// this session working on", which neither the status nor the tool-level activity
    /// gives. Nil until a prompt has been seen: a session that is merely open has
    /// been asked for nothing, and the row says so by having no such line at all.
    ///
    /// Set from the transcript (the full prompt) and from `UserPromptSubmit` (the
    /// same prompt, trimmed by the hook so its datagram fits). A short follow-up does
    /// not overwrite it — see `TaskText.replaces`.
    public var taskText: String? = nil
    /// The agent's task list — see `TaskStep`. Empty until the agent writes one.
    public var steps: [TaskStep] = []
    /// What the last finished turn handed over — see `Handoff`. Nil while working:
    /// the next turn has begun and the old result is stale.
    public var handoff: Handoff? = nil
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

    /// The step the agent is on: the first in progress, else the first still pending.
    /// Nil when the list is done or absent — the row then shows nothing rather than
    /// a finished step pretending to be current.
    public var currentStep: TaskStep? {
        steps.first(where: { $0.status == .inProgress }) ?? steps.first(where: { $0.status == .pending })
    }

    /// Completed over total, nil with no list.
    public var stepProgress: (done: Int, total: Int)? {
        guard !steps.isEmpty else { return nil }
        return (steps.filter { $0.status == .completed }.count, steps.count)
    }
}

public enum AggregateStatus: Equatable, Sendable {
    case sleeping
    case working(Int)
    case waiting(Int)
    case done
    case problem
}

/// The colour a state is shown in, named by meaning rather than by hue so the two
/// surfaces (the island counter and the floating badge) map it to the same SwiftUI
/// `Color` and can never drift into two colour systems. Views map it to
/// green/orange/blue/red/grey.
public enum MascotTone: Equatable, Sendable { case working, waiting, done, problem, sleeping }

/// The single mark the user sees, produced once by `SessionStore.indicator` and
/// rendered by both the island counter and the floating badge — see that property.
public struct MascotIndicator: Equatable, Sendable {
    public let tone: MascotTone   // colour of the count / dot
    public let count: Int         // number to show; 0 means "dot only, no number"
    public let crashedMarker: Bool// a red marker in ADDITION to an active count
    public init(tone: MascotTone, count: Int, crashedMarker: Bool) {
        self.tone = tone; self.count = count; self.crashedMarker = crashedMarker
    }
}

/// One session's own dot in the island's cluster, carrying its session id rather
/// than just its colour. `SessionStore.dots` used to hand back bare `[MascotTone]`,
/// which the island keyed by array offset — but `ordered` ranks by status, so a
/// session whose tone changed moved to a different offset and a *different* dot
/// crossfaded and re-animated in its place. Identity by `id` lets the island animate
/// the session's own dot: it slides to its new slot and recolours in place.
public struct SessionDot: Equatable, Sendable, Identifiable {
    public let id: String
    public let tone: MascotTone
    public init(id: String, tone: MascotTone) {
        self.id = id; self.tone = tone
    }
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
    /// The prompt the user typed, on `UserPromptSubmit`. Claude Code sends it in
    /// full; `codecat-hook` trims it to `TaskText.maxLength` before forwarding,
    /// because the payload has to fit in a 2 048-byte datagram — a longer one is not
    /// truncated in transit, it is lost whole.
    public let prompt: String?

    public init(hookEventName: String, sessionId: String, cwd: String?, message: String?,
                hostPID: pid_t? = nil, hostBundlePath: String? = nil,
                hostBundleID: String? = nil, tty: String? = nil, source: String? = nil,
                agentPID: pid_t? = nil, prompt: String? = nil) {
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
        self.prompt = prompt
    }

    enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
        case sessionId = "session_id"
        case cwd, message, source, prompt
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

    /// What the user asked for, when this entry is a typed prompt — see
    /// `TranscriptParser.taskText`. Nil on every other entry, which is most of them:
    /// only the line where a turn begins sets the task.
    public let taskText: String?
    /// Changes to the session's task list carried by this line — see `StepsUpdate`.
    /// Empty for almost every line.
    public let stepsUpdates: [StepsUpdate]
    /// The assistant's text on the line that ends the turn — the message the user
    /// would read in the terminal. Nil on every other line.
    public let finalText: String?

    public init(sessionId: String, projectPath: String, description: String, timestamp: Date,
                isSubagent: Bool = false, endsTurn: Bool = false, taskText: String? = nil,
                stepsUpdates: [StepsUpdate] = [], finalText: String? = nil) {
        self.sessionId = sessionId
        self.projectPath = projectPath
        self.description = description
        self.timestamp = timestamp
        self.isSubagent = isSubagent
        self.endsTurn = endsTurn
        self.taskText = taskText
        self.stepsUpdates = stepsUpdates
        self.finalText = finalText
    }
}
