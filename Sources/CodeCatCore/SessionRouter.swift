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
    case automationDenied
    /// The tab is gone — it was closed since the session started.
    case tabNotFound
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

/// User-facing Russian text for jump outcomes. Kept next to the outcomes so the
/// "no silent refusals" rule can be enforced by a test over every case.
public enum JumpMessages {

    /// The alert to show, or nil when the outcome needs none — a jump that worked
    /// already put the user where they wanted to be.
    public static func alert(for outcome: JumpOutcome) -> (title: String, body: String)? {
        switch outcome {
        case .switchedToTab, .switchedToApplication:
            return nil
        case .automationDenied:
            return ("Нет разрешения на автоматизацию",
                    "Чтобы попадать сразу во вкладку терминала, нужно разрешение на автоматизацию — его можно выдать в Системных настройках, «Конфиденциальность и безопасность» → «Автоматизация». Пока вывел приложение вперёд.")
        case .tabNotFound:
            return ("Вкладку найти не удалось",
                    "Похоже, вкладку с этой сессией уже закрыли. Вывел приложение вперёд.")
        case .hostGone:
            return ("Сессия закрыта",
                    "Приложение, в котором работала эта сессия, больше не запущено.")
        case .failed(let detail):
            return ("Не удалось перейти к сессии", "Ошибка: \(detail)")
        }
    }

    /// The small caption under a row that cannot be clicked.
    public static func rowHint(for reason: UnavailableReason) -> String {
        switch reason {
        case .noHostRecorded:
            return "переход недоступен — сессия запущена до CodeCat"
        case .hostGone:
            return "переход недоступен — приложение сессии закрыто"
        }
    }
}
