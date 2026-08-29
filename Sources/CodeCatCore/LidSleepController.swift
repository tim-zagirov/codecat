import Foundation

/// Drives the closed-lid sleep-prevention flag (`pmset -a disablesleep`), the one piece
/// of sleep policy that macOS honors even with the lid closed. `PowerManager`'s IOKit
/// assertion keeps the Mac awake with the lid open (or closed but externally displayed);
/// this controller covers the lid-closed case, which requires the system-wide
/// `disablesleep` flag and therefore elevated rights.
///
/// Elevated rights are obtained out of band: a one-time install (admin password via
/// `osascript`, see `scripts/install-lid-mode.sh`) drops a `sudoers.d` rule that lets the
/// current user run exactly `sudo -n pmset -a disablesleep 1` and
/// `sudo -n pmset -a disablesleep 0` without a password, plus a LaunchDaemon that resets
/// the flag at boot as a safety net if the app dies while it is set.
///
/// Call contract (owned by the caller, e.g. the app, which drives it with the same
/// `shouldPreventSleep` bit it feeds `PowerManager`):
/// - Call `update(shouldPreventSleep:)` whenever that bit changes. Idempotent: calling it
///   again with the same value never re-runs the command.
/// - Toggle `isEnabled` for the user's on/off preference; turning it off immediately
///   clears an active flag.
/// - Call `resetOnExit()` when the app terminates. Safe to call whether or not the flag
///   is currently set.
///
/// The controller never records the flag as "set" unless the underlying command actually
/// succeeded (exit status 0), in either direction. That is what makes `resetOnExit()` and
/// the `isEnabled` toggle reliable: if a clearing attempt itself fails, `lidSleepDisabled`
/// stays `true` so a later attempt is not skipped, and the flag is never left set on the
/// system while the controller believes it is clear.
public final class LidSleepController {
    private let runner: ([String]) -> Int32

    /// Whether `pmset -a disablesleep 1` is currently believed to be in effect, i.e. the
    /// last successful call was "on" and no later "off" call has succeeded since.
    public private(set) var lidSleepDisabled = false

    /// User-facing on/off preference for the feature. Turning it off releases an active
    /// flag immediately, independent of `update(shouldPreventSleep:)`.
    public var isEnabled = false {
        didSet {
            if !isEnabled && lidSleepDisabled {
                setFlag(false)
            }
        }
    }

    public init(runner: @escaping ([String]) -> Int32 = LidSleepController.defaultRunner) {
        self.runner = runner
    }

    /// Mirrors the same `shouldPreventSleep` bit the caller feeds `PowerManager`. A no-op
    /// while `isEnabled` is `false`, and idempotent for repeated calls with the same value.
    public func update(shouldPreventSleep: Bool) {
        guard isEnabled else { return }
        if shouldPreventSleep && !lidSleepDisabled {
            setFlag(true)
        }
        if !shouldPreventSleep && lidSleepDisabled {
            setFlag(false)
        }
    }

    /// Clears the flag if it is currently believed to be set. Safe to call unconditionally
    /// (e.g. from an app-termination handler) whether or not the flag was ever set.
    public func resetOnExit() {
        if lidSleepDisabled {
            setFlag(false)
        }
    }

    private func setFlag(_ on: Bool) {
        let args = ["/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a",
                     "disablesleep", on ? "1" : "0"]
        if runner(args) == 0 {
            lidSleepDisabled = on
        }
    }

    /// Whether the one-time installer (`scripts/install-lid-mode.sh`) has been run on
    /// this Mac, i.e. whether the passwordless sudoers rule exists.
    public static var isHelperInstalled: Bool {
        FileManager.default.fileExists(atPath: "/etc/sudoers.d/codecat")
    }

    /// Shells out to `sudo -n pmset -a disablesleep <0|1>` for real. Never used by tests —
    /// every test supplies its own runner closure so no test ever touches `sudo`/`pmset`.
    public static let defaultRunner: ([String]) -> Int32 = { args in
        let task = Process()
        task.executableURL = URL(fileURLWithPath: args[0])
        task.arguments = Array(args.dropFirst())
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus
        } catch {
            return -1
        }
    }
}
