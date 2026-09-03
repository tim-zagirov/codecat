import Foundation

/// A scripted stand-in for real Claude Code sessions, used by `--demo` to walk the
/// mascot through every state it can be in.
///
/// This is what `scripts/capture-screenshots.sh` drives: the four states the cat
/// has are otherwise only reachable by having agents actually run, which makes a
/// screenshot of "waiting for you" a matter of sitting there until one asks a
/// question. Recording a landing-page loop that way is not practical.
///
/// It is here, in the core, rather than in the app for one reason: it can then be
/// tested. A demo that quietly stopped producing one of the four states would
/// still *look* fine — a cat cycling through three poses is not obviously wrong —
/// so the property worth guarding is that the cycle really reaches all of them.
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
                source: name == "SessionStart" ? "startup" : nil)
        }
    }

    /// The activity line each session shows in `phase`, as the transcript watcher
    /// would report it. Without these every row would read "started on the task",
    /// which is exactly the detail a screenshot is meant to show.
    public static func activities(for phase: Phase, now: Date) -> [TranscriptActivity] {
        guard phase == .working || phase == .waiting else { return [] }
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
            return TranscriptActivity(sessionId: id, projectPath: projects[index],
                                      description: descriptions[index], timestamp: now,
                                      isSubagent: false, endsTurn: false)
        }
    }

    /// The phase `step` steps into the loop.
    public static func phase(atStep step: Int) -> Phase {
        Phase.allCases[((step % Phase.allCases.count) + Phase.allCases.count) % Phase.allCases.count]
    }
}
