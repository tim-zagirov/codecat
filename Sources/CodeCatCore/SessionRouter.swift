import Foundation

/// Where a click on a session row should send the user, in descending precision.
public enum JumpRoute: Equatable, Sendable {
    /// A terminal whose scripting interface can select the exact tab by tty.
    case terminalTab(bundleID: String, bundlePath: String, pid: pid_t, tty: String)
    /// The owning application, brought forward. No window-level aiming: sessions of
    /// the desktop Claude app are child processes with no windows of their own, so
    /// picking a window would be guesswork (see the design spec).
    case application(pid: pid_t, bundlePath: String)
    case unavailable(reason: UnavailableReason)

    /// The bundle this route was computed for, or nil when there is nothing to jump
    /// to. The executor must re-check it before activating: a pid outlives the
    /// process that owned it, and macOS recycles pids, so `NSRunningApplication(
    /// processIdentifier:)` can resolve to an entirely unrelated program.
    public var bundlePath: String? {
        switch self {
        case .terminalTab(_, let bundlePath, _, _): return bundlePath
        case .application(_, let bundlePath): return bundlePath
        case .unavailable: return nil
        }
    }
}

public enum UnavailableReason: Equatable, Sendable {
    /// The session was discovered by the transcript watcher; the hook never saw it,
    /// so nothing is known about where it runs.
    case noHostRecorded
    /// The owning application is no longer running.
    case hostGone
}

/// Pure choice of a jump route. No system access beyond the injected liveness check,
/// so every combination of inputs is testable on fixed values.
public enum SessionRouter {

    /// Terminals whose AppleScript interface exposes a tab's tty, so the exact tab
    /// can be selected. Any other host falls back to bringing the app forward.
    public static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
    ]

    public static func route(for session: Session, isHostRunning: (pid_t) -> Bool) -> JumpRoute {
        guard let pid = session.hostPID,
              let bundlePath = session.hostBundlePath, !bundlePath.isEmpty else {
            return .unavailable(reason: .noHostRecorded)
        }
        guard isHostRunning(pid) else { return .unavailable(reason: .hostGone) }

        if let bundleID = session.hostBundleID, terminalBundleIDs.contains(bundleID),
           let tty = session.tty, !tty.isEmpty {
            return .terminalTab(bundleID: bundleID, bundlePath: bundlePath, pid: pid, tty: tty)
        }
        return .application(pid: pid, bundlePath: bundlePath)
    }

    /// `kill(pid, 0)` performs the permission and existence check without sending a
    /// signal. `EPERM` means the process exists but belongs to someone else, which
    /// still counts as running.
    public static func isProcessRunning(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}

/// What actually happened when a route was executed.
public enum JumpOutcome: Equatable, Sendable {
    case switchedToTab
    case switchedToApplication
    /// The user declined the one-time automation permission for the terminal.
    /// `fellBack` records whether the executor's fallback — bringing the terminal
    /// app forward — actually worked, so the message never claims a switch that did
    /// not happen.
    case automationDenied(fellBack: Bool)
    /// The tab is gone — it was closed since the session started. `fellBack` as above.
    case tabNotFound(fellBack: Bool)
    case hostGone
    case failed(String)
}

/// Executing a route is the app layer's job (AppKit + AppleScript); the protocol is
/// what keeps `AppState`'s handling of outcomes testable, the same way `runner` does
/// for `LidSleepController`.
public protocol JumpExecuting {
    /// Implementations must not block the caller, and must invoke `completion` on
    /// the main queue — this protocol cannot enforce either, so callers rely on the
    /// contract, not on anything checkable here.
    func perform(_ route: JumpRoute, completion: @escaping (JumpOutcome) -> Void)
}

/// User-facing text for jump outcomes. Kept next to the outcomes so the
/// "no silent refusals" rule can be enforced by a test over every case.
public enum JumpMessages {

    /// The alert to show, or nil when the outcome needs none — a jump that worked
    /// already put the user where they wanted to be.
    public static func alert(for outcome: JumpOutcome) -> (title: String, body: String)? {
        switch outcome {
        case .switchedToTab, .switchedToApplication:
            return nil
        case .automationDenied(let fellBack):
            let permission = L10n.t("jump.automation.denied.body",
                "To open the terminal tab directly, CodeCat needs automation permission. "
                + "Grant it in System Settings, under Privacy & Security → Automation.")
            return (L10n.t("jump.automation.denied.title", "No automation permission"),
                    fellBack
                        ? permission + " " + broughtForward
                        : permission + " " + couldNotBringForward)
        case .tabNotFound(let fellBack):
            let closed = L10n.t("jump.tab.notfound.body", "That session's tab looks closed.")
            return (L10n.t("jump.tab.notfound.title", "Couldn't find the tab"),
                    fellBack
                        ? closed + " " + broughtForward
                        : closed + " " + couldNotBringForward)
        case .hostGone:
            return (L10n.t("jump.host.gone.title", "Session closed"),
                    L10n.t("jump.host.gone.body",
                           "The app this session was running in is no longer open."))
        case .failed(let detail):
            return (L10n.t("jump.failed.title", "Couldn't jump to the session"),
                    L10n.f("jump.failed.body", "Error: %@", detail))
        }
    }

    /// The two endings every recoverable outcome needs: whether CodeCat managed to
    /// bring the terminal forward instead. Written once because four different
    /// messages end with one or the other, and a translation that drifted between
    /// them would read as two different promises about the same fallback.
    private static var broughtForward: String {
        L10n.t("jump.fallback.done", "Brought the app forward instead.")
    }

    private static var couldNotBringForward: String {
        L10n.t("jump.fallback.failed",
               "Bringing the app forward didn't work either — switch to it yourself.")
    }

    // MARK: - Details carried inside `.failed`
    //
    // Every user-facing string lives here, including the ones the app layer's
    // executor produces, so the "no silent refusals" test can see all of them.

    /// The app exists but macOS refused to bring it forward.
    public static var activationRefusedDetail: String {
        L10n.t("jump.detail.activation.refused", "couldn't bring the app forward")
    }

    /// The tab-selection script could not even be compiled.
    public static var scriptBuildFailedDetail: String {
        L10n.t("jump.detail.script.build.failed", "couldn't compile the AppleScript")
    }

    /// A deadline expired. Which deadline matters: one set because the automation
    /// permission had not been decided yet may have run out with the consent panel
    /// still on screen — in which case the terminal was never asked at all. But it
    /// may equally have run out after the user answered the panel and the terminal
    /// itself wedged. Neither wording may assert which happened: the hedge is what
    /// makes both true, and it still tells the user the one thing worth trying.
    public static func timedOutDetail(awaitingConsent: Bool) -> String {
        awaitingConsent
            ? L10n.t("jump.detail.timeout.consent",
                     "the terminal hasn't answered yet — the automation permission dialog "
                     + "may still be open: answer it and click the session again")
            : L10n.t("jump.detail.timeout", "the terminal didn't answer")
    }

    /// A previous tab-selection script is still stuck, so this jump could not even be
    /// attempted. Says whether the app was brought forward instead, so the message
    /// never claims a switch that did not happen.
    public static func terminalStillBusyDetail(fellBack: Bool) -> String {
        let head = L10n.t("jump.detail.busy", "The previous jump to the terminal hasn't finished.")
        return fellBack ? head + " " + broughtForward : head + " " + couldNotBringForward
    }

    /// The script ran but returned something neither marker matches.
    public static var unexpectedTerminalReplyDetail: String {
        L10n.t("jump.detail.unexpected.reply", "unexpected reply from the terminal")
    }

    /// An AppleScript error that is none of the classified ones.
    public static func appleScriptFailureDetail(_ message: String) -> String {
        "AppleScript: \(message)"
    }

    /// Appends what the fallback actually did to a `.failed` detail. `.failed` owes
    /// the user a destination just as much as the two recoverable outcomes do, and
    /// a detail like "the terminal didn't answer" on its own leaves a user whose
    /// fallback was refused with nothing to do next.
    public static func failureDetail(_ detail: String, fellBack: Bool) -> String {
        detail + ". " + (fellBack ? broughtForward : couldNotBringForward)
    }

    /// The small caption under a row that cannot be clicked.
    public static func rowHint(for reason: UnavailableReason) -> String {
        switch reason {
        case .noHostRecorded:
            return L10n.t("jump.hint.no.host",
                          "can't jump — this session started before CodeCat did")
        case .hostGone:
            return L10n.t("jump.hint.host.gone",
                          "can't jump — this session's app is closed")
        }
    }
}
