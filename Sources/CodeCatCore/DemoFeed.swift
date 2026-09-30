import Foundation

/// A scripted stand-in for real Claude Code sessions, used by `--demo` to walk the
/// mascot through every state it can be in.
///
/// This is what `scripts/capture-screenshots.sh` drives: the four states the loop
/// walks are otherwise only reachable by having agents actually run, which makes a
/// screenshot of "waiting for you" a matter of sitting there until one asks a
/// question — the fifth state, `.problem`, is deliberately left out of the loop
/// and reachable only through `Pin.problem` below. Recording a landing-page loop
/// that way is not practical.
///
/// It is here, in the core, rather than in the app for one reason: it can then be
/// tested. A demo that quietly stopped producing one of the four looped states
/// would still *look* fine — a cat cycling through three poses is not obviously
/// wrong — so the property worth guarding is that the cycle really reaches all of
/// them.
///
/// It produces the same `HookEvent`s a real hook would, so nothing downstream can
/// tell it apart or needs a demo branch of its own. It never writes to disk and
/// never touches `~/.claude`.
public enum DemoFeed {

    /// The projects in the scripted feed. Three, because the panel's job is to show
    /// several sessions at once and one row does not demonstrate that.
    public static let projects = ["/Users/you/Projects/codecat",
                                  "/Users/you/Projects/orbit-api",
                                  "/Users/you/Projects/studio-site"]

    public static let sessionIDs = ["demo-0001", "demo-0002", "demo-0003"]

    /// Three more projects for the pins that need more than three sessions: the
    /// wing's count form (six) and the showcase list (two of them idle).
    public static let moreProjects = ["/Users/you/Projects/site",
                                      "/Users/you/Projects/notes-cli",
                                      "/Users/you/Projects/infra"]

    /// `demo-0001`, `demo-0002`… — the first three are `sessionIDs`.
    public static func sessionID(_ index: Int) -> String { String(format: "demo-%04d", index + 1) }

    private static var allProjects: [String] { projects + moreProjects }

    /// What each session was asked for. The third has none: it is open and has been
    /// given nothing to do, and a demo that never shows that row hides half of what
    /// the list says. Written the way people really write prompts — a request, not a
    /// label — because the row's whole claim is that it shows the user's own words.
    public static let tasks = [
        "the cards duplicate when you scroll the feed",
        "bump the SDK and fix what breaks",
        nil,
    ]

    /// One step of the loop. Each is a full description of where all three sessions
    /// should be, not a delta, so a capture script can jump straight to the state it
    /// wants to photograph.
    public enum Phase: Int, CaseIterable, Sendable {
        /// Sessions open, nothing running. The cat sleeps, no badge.
        case idle
        /// Two agents working. The badge counts them.
        case working
        /// One agent is asking; the others carry on. The cat waves.
        case waiting
        /// Everything finished. The cat stretches and settles.
        case done

        /// The hook event that puts session `index` into this phase.
        func event(for index: Int) -> String {
            switch self {
            case .idle: return "SessionStart"
            case .working: return index == 2 ? "SessionStart" : "UserPromptSubmit"
            case .waiting: return index == 0 ? "Notification" : "UserPromptSubmit"
            case .done: return "Stop"
            }
        }
    }

    /// The events that move every session into `phase`, in order.
    ///
    /// `Notification` carries a message because `SessionStore` reads it to tell a
    /// permission prompt from a question — the demo asks a question.
    public static func events(for phase: Phase) -> [HookEvent] {
        sessionIDs.enumerated().map { index, id in
            let name = phase.event(for: index)
            return HookEvent(
                hookEventName: name,
                sessionId: id,
                cwd: projects[index],
                message: name == "Notification" ? "Claude is asking a question" : nil,
                source: name == "SessionStart" ? "startup" : nil,
                // Only `UserPromptSubmit` carries a prompt, exactly as in the real
                // payload: a session that was never asked for anything must stay
                // without a task here too.
                prompt: name == "UserPromptSubmit" ? tasks[index] : nil)
        }
    }

    /// The first session's plan — five steps with the third under way, so a
    /// screenshot shows a bar that is neither empty nor full.
    public static let steps: [TaskStep] = [
        TaskStep(id: "0", title: "Find where the cards duplicate", activeForm: "Finding where the cards duplicate", status: .completed),
        TaskStep(id: "1", title: "Write a failing test", activeForm: "Writing a failing test", status: .completed),
        TaskStep(id: "2", title: "Fix the pagination cursor", activeForm: "Fixing the pagination cursor", status: .inProgress),
        TaskStep(id: "3", title: "Run the feed tests", activeForm: "Running the feed tests", status: .pending),
        TaskStep(id: "4", title: "Take screenshots for the PR", activeForm: "Taking screenshots for the PR", status: .pending),
    ]

    /// The second session's final message — a summary line and three links, one of
    /// each kind a chip most often is.
    public static let handoffText = """
        Done — tests are green, release 0.4.1 is built.

        See: http://localhost:4321 and https://github.com/you/orbit-api/pull/12
        Mockup: https://www.figma.com/design/demo/orbit
        """

    /// The activity line each session shows in `phase`, as the transcript watcher
    /// would report it. Without these every row would read "started on the task",
    /// which is exactly the detail a screenshot is meant to show.
    public static func activities(for phase: Phase, now: Date) -> [TranscriptActivity] {
        guard phase != .idle else { return [] }
        if phase == .done {
            // The second session's turn ends in the transcript, with its text — the
            // hook alone (`Stop`) has no message to hand over.
            return [TranscriptActivity(sessionId: sessionIDs[1], projectPath: projects[1],
                                       description: L10n.t("activity.done", "finished the task"),
                                       timestamp: now.addingTimeInterval(1), endsTurn: true,
                                       finalText: handoffText)]
        }
        let descriptions = [
            L10n.f("activity.editing.file", "editing %@", "IslandLayout.swift"),
            L10n.t("activity.running", "running a command"),
            L10n.t("activity.searching", "searching the code"),
        ]
        return sessionIDs.enumerated().compactMap { index, id in
            // The waiting session's own line must not be overwritten: it is the one
            // the screenshot is about.
            if phase == .waiting && index == 0 { return nil }
            if phase == .working && index == 2 { return nil }
            // A second after the phase's hooks, not at the same instant as them:
            // `SessionStore.apply(activity:)` ignores an activity that is not LATER
            // than the session's last activity, and the app applies both from one
            // `Date()`. With an equal timestamp every one of these was dropped and
            // the rows kept the hook's placeholder — which is what the shipped
            // README screenshots show.
            return TranscriptActivity(sessionId: id, projectPath: projects[index],
                                      description: descriptions[index],
                                      timestamp: now.addingTimeInterval(1),
                                      isSubagent: false, endsTurn: false,
                                      stepsUpdates: index == 0 ? [.replaceAll(steps)] : [])
        }
    }

    /// The phases a pinned phase needs applied ahead of it, so a cold start lands
    /// where the loop would have been. A session that is waiting on its user, or that
    /// has finished, was asked for something first; pinned straight to that phase for
    /// a screenshot it would otherwise be waiting over nothing in particular.
    public static func leadIn(for phase: Phase) -> [Phase] {
        switch phase {
        case .waiting, .done: return [.working]
        case .idle, .working: return []
        }
    }

    /// The phase `step` steps into the loop.
    public static func phase(atStep step: Int) -> Phase {
        Phase.allCases[((step % Phase.allCases.count) + Phase.allCases.count) % Phase.allCases.count]
    }

    /// What `--demo-phase=` can hold: a phase of the loop, the one state the loop
    /// deliberately never reaches, and the fixed scenes the island's captures
    /// compare against Figma.
    public enum Pin: Equatable, Sendable {
        case phase(Phase)
        /// A session died. Not a phase of the loop — see `DemoFeedTests` — but the
        /// fifth pose the mascot has, and a screenshot of it has to be possible.
        case problem
        /// The first session alone, in `phase`: the right wing's single-session
        /// forms — the progress ring, the done check, a lone dot.
        case single(Phase)
        /// Six agents working: the right wing's count form.
        case many
        /// Every card kind at once, like Figma's "Full list" frame.
        case showcase
        /// No sessions at all: the empty and first-run states.
        case empty
    }

    /// Puts `store` into `pin`'s scene. Each phase is applied two seconds after the
    /// one before it: `SessionStore.apply(activity:)` ignores an activity that is not
    /// later than the session's last, and the phases' activities carry `now + 1`.
    public static func apply(_ pin: Pin, to store: SessionStore, now: Date) {
        switch pin {
        case .phase(let phase):
            applyPhases(leadIn(for: phase) + [phase], to: store, now: now, only: nil)
        case .single(let phase):
            applyPhases(leadIn(for: phase) + [phase], to: store, now: now, only: sessionIDs[0])
        case .problem:
            applyProblem(to: store, now: now)
        case .many:
            for (index, path) in allProjects.enumerated() {
                store.apply(hook: HookEvent(hookEventName: "UserPromptSubmit", sessionId: sessionID(index),
                                            cwd: path, message: nil, prompt: manyTasks[index]), now: now)
            }
        case .showcase:
            applyShowcase(to: store, now: now)
        case .empty:
            break
        }
    }

    private static let manyTasks = [
        "the cards duplicate when you scroll the feed",
        "bump the SDK and fix what breaks",
        "build release 0.4.1",
        "move the landing page to Astro",
        "port the parser to Swift",
        "rotate the staging certificates",
    ]

    private static func applyPhases(_ phases: [Phase], to store: SessionStore, now: Date, only id: String?) {
        for (offset, phase) in phases.enumerated() {
            let at = now.addingTimeInterval(Double(offset) * 2)
            for event in events(for: phase) where id == nil || event.sessionId == id {
                store.apply(hook: event, now: at)
            }
            for activity in activities(for: phase, now: at) where id == nil || activity.sessionId == id {
                store.apply(activity: activity)
            }
        }
    }

    /// Order of `SessionStore.ordered`: waiting, working (by start), done, idle (by
    /// start) — so the six sessions start a tenth of a second apart, in the order
    /// the list should show them within each status.
    private static func applyShowcase(to store: SessionStore, now: Date) {
        // index: 0 codecat, 1 orbit-api, 2 studio-site, 3 site, 4 notes-cli, 5 infra
        let order = [0, 1, 3, 2, 4, 5]
        for (rank, index) in order.enumerated() {
            store.apply(hook: HookEvent(hookEventName: "SessionStart", sessionId: sessionID(index),
                                        cwd: allProjects[index], message: nil, source: "startup"),
                        now: now.addingTimeInterval(Double(rank) * 0.1))
        }
        // Asked in list order too, in case a prompt restarts a session's clock.
        let prompts = [(0, "run the tests before the release"), (1, tasks[1]!), (3, tasks[0]!),
                       (2, "build release 0.4.1")]
        for (rank, (index, prompt)) in prompts.enumerated() {
            store.apply(hook: HookEvent(hookEventName: "UserPromptSubmit", sessionId: sessionID(index),
                                        cwd: allProjects[index], message: nil, prompt: prompt),
                        now: now.addingTimeInterval(1 + Double(rank) * 0.1))
        }
        store.apply(activity: TranscriptActivity(
            sessionId: sessionID(3), projectPath: allProjects[3],
            description: L10n.f("activity.editing.file", "editing %@", "Feed.swift"),
            timestamp: now.addingTimeInterval(2), isSubagent: false, endsTurn: false,
            stepsUpdates: [.replaceAll(steps)]))
        store.apply(activity: TranscriptActivity(
            sessionId: sessionID(1), projectPath: allProjects[1],
            description: L10n.t("activity.running", "running a command"),
            timestamp: now.addingTimeInterval(2), isSubagent: false, endsTurn: false))
        let later = now.addingTimeInterval(3)
        store.apply(hook: HookEvent(hookEventName: "Notification", sessionId: sessionID(0), cwd: allProjects[0],
                                    message: "Claude is asking a question"), now: later)
        store.apply(hook: HookEvent(hookEventName: "Stop", sessionId: sessionID(2), cwd: allProjects[2],
                                    message: nil), now: later)
        store.apply(activity: TranscriptActivity(
            sessionId: sessionID(2), projectPath: allProjects[2],
            description: L10n.t("activity.done", "finished the task"),
            timestamp: now.addingTimeInterval(4), endsTurn: true, finalText: handoffText))
    }

    /// Puts the store into `.problem` the way it really arises: the `working` phase,
    /// then the store's own staleness rule finding one session silent with no live
    /// process. One session stops, one keeps working, one stays idle — a picture of
    /// the state, not of three dead rows.
    public static func applyProblem(to store: SessionStore, now: Date) {
        for event in events(for: .working) { store.apply(hook: event, now: now) }
        let later = now.addingTimeInterval(121)
        store.apply(hook: HookEvent(hookEventName: "UserPromptSubmit",
                                    sessionId: sessionIDs[0], cwd: projects[0],
                                    message: nil, source: nil), now: later)
        // 121 s of silence for the second session, against a 120 s threshold and no
        // `claude` process anywhere: the rule in `SessionStore.reconcile`.
        store.reconcile(claudeProcessCount: 0, now: later, isAgentAlive: { _ in false })
        store.apply(activity: TranscriptActivity(
            sessionId: sessionIDs[0], projectPath: projects[0],
            description: L10n.f("activity.editing.file", "editing %@", "IslandLayout.swift"),
            timestamp: later.addingTimeInterval(1), isSubagent: false, endsTurn: false))
    }
}
