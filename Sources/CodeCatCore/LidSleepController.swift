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
    private let flagReader: () -> Bool?
    private let bridgeRunner: (Int) -> Bool

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

    public init(runner: @escaping ([String]) -> Int32 = LidSleepController.defaultRunner,
                flagReader: @escaping () -> Bool? = LidSleepController.defaultFlagReader,
                bridgeRunner: @escaping (Int) -> Bool = LidSleepController.defaultBridgeRunner) {
        self.runner = runner
        self.flagReader = flagReader
        self.bridgeRunner = bridgeRunner
    }

    /// Mirrors the same `shouldPreventSleep` bit the caller feeds `PowerManager`. A no-op
    /// while `isEnabled` is `false`, and idempotent for repeated calls with the same value.
    /// Cache-only and cheap: does not consult `flagReader`, so it is safe to call on every
    /// hook event. Use `reconcile(shouldPreventSleep:)` on a slower cadence to correct for
    /// drift between this cache and the real system flag.
    public func update(shouldPreventSleep: Bool) {
        guard isEnabled else { return }
        if shouldPreventSleep && !lidSleepDisabled {
            setFlag(true)
        }
        if !shouldPreventSleep && lidSleepDisabled {
            setFlag(false)
        }
    }

    /// Like `update(shouldPreventSleep:)`, but first re-synchronizes `lidSleepDisabled`
    /// against the real `SleepDisabled` flag (read via `flagReader`, a read-only query that
    /// needs no `sudo`) before applying the same decision logic. This is the only path that
    /// notices out-of-band drift — someone running `pmset` by hand, another tool, or the
    /// watchdog daemon firing in an edge case — and corrects it. Meant to be called from an
    /// infrequent maintenance timer, not from every hook event, since the reader spawns a
    /// subprocess. When the reader cannot determine the real state (`nil`), the cached
    /// belief is left untouched so an unreadable state never triggers a spurious command.
    public func reconcile(shouldPreventSleep: Bool) {
        guard isEnabled else { return }
        if let actual = flagReader() {
            lidSleepDisabled = actual
        }
        update(shouldPreventSleep: shouldPreventSleep)
    }

    /// Clears the flag if it is currently believed to be set. Safe to call unconditionally
    /// (e.g. from an app-termination handler) whether or not the flag was ever set.
    public func resetOnExit() {
        if lidSleepDisabled {
            setFlag(false)
        }
    }

    private func setFlag(_ on: Bool) {
        // Мост ставится ДО снятия флага, иначе он опоздает: сон наступает в те же
        // миллисекунды, что и запись pmset. См. bridgeIdleSleep.
        if !on { bridge(Self.bridgeSeconds) }
        let args = ["/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a",
                     "disablesleep", on ? "1" : "0"]
        if runner(args) == 0 {
            lidSleepDisabled = on
        }
    }

    /// Сколько секунд удерживать мак от сна сразу после снятия `disablesleep`.
    ///
    /// Смысл окна — дать маку прожить обычную паузу вместо мгновенного провала в
    /// сон, чтобы за это время засчиталось живое действие человека (он только что
    /// нажал «Выйти» и почти наверняка ещё за машиной). Если человек всё-таки ушёл,
    /// окно истечёт и мак уснёт сам — это правильно, мешать этому не надо.
    public static let bridgeSeconds = 60

    /// Почему это вообще нужно — замерено на живой машине, а не выведено из
    /// документации.
    ///
    /// `pmset -a disablesleep 0` заставляет ядро перечитать настройки сна. Всё
    /// время, пока флаг стоял, простой продолжал накапливаться, поэтому при
    /// перечитывании мак видит простой, давно перешедший порог, и засыпает
    /// НЕМЕДЛЕННО — в журнале это `sleep reason Software Sleep`, то есть сон по
    /// программному запросу, а не по простою. Замер на выходе из приложения:
    ///
    ///     11:20:06.018  powerd: Energy Saver Prefs have changed   (это наш pmset)
    ///     11:20:06.055  kernel: PMRD: sleep reason Software Sleep (через 37 мс)
    ///     11:20:06.094  corebrightnessd: Will Sleep, яркость 0    (экран погас)
    ///
    /// Контрольный опыт: тот же выход при ВЫКЛЮЧЕННОМ режиме крышки — сна нет
    /// вовсе. Виноват именно этот `pmset`, а не снятие IOKit-удержания: отдельно
    /// проверено, что `IOPMAssertionDeclareUserActivity` (то же, что `caffeinate -u`)
    /// этот путь не перекрывает — мак засыпает всё равно.
    ///
    /// Работает `caffeinate -i` — обычное удержание сна по простою. Он ОТДЕЛЬНЫЙ
    /// процесс намеренно: удержание принадлежит своему процессу, и взятое внутри
    /// CodeCat умерло бы вместе с ним через миллисекунды (в журнале powerd это
    /// видно как `ClientDied`), то есть ровно тогда, когда оно и нужно.
    private func bridge(_ seconds: Int) {
        _ = bridgeRunner(seconds)
    }

    /// Запускает `caffeinate -i -t <seconds>` отвязанно. Подменяется в тестах —
    /// ни один тест не должен порождать настоящий процесс.
    public static let defaultBridgeRunner: (Int) -> Bool = { seconds in
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        task.arguments = ["-i", "-t", String(seconds)]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            // Намеренно НЕ ждём: процесс должен пережить наш выход. launchd
            // усыновит его, когда мы умрём.
            return true
        } catch {
            // Мост — удобство, а не корректность. Не смогли — снимаем флаг всё
            // равно: оставить disablesleep поднятым куда хуже, чем разбудить
            // человека погасшим экраном.
            return false
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

    /// Parses the `SleepDisabled` line out of `pmset -g` output, e.g.
    /// " SleepDisabled\t\t1". Returns `nil` when no such line is present, which the
    /// caller treats as "state unknown" rather than guessing. Split out from
    /// `defaultFlagReader` so this logic is testable on fixed strings without spawning
    /// anything, the same way `ProcessScanner.count(fromPgrepOutput:)` is split from
    /// `claudeProcessCount()`.
    static func parseSleepDisabled(fromPmsetOutput output: String) -> Bool? {
        for line in output.split(separator: "\n") {
            let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
                .flatMap { $0.split(separator: "\t", omittingEmptySubsequences: true) }
            guard let idx = tokens.firstIndex(of: "SleepDisabled"), idx + 1 < tokens.count else {
                continue
            }
            switch tokens[idx + 1] {
            case "1": return true
            case "0": return false
            default: return nil
            }
        }
        return nil
    }

    /// Shells out to the read-only `pmset -g` (no `sudo` needed) and parses out the real
    /// `SleepDisabled` state. Reads stdout to EOF before calling `waitUntilExit()` — waiting
    /// first can deadlock if the child fills the pipe buffer, the same class of bug already
    /// fixed in `ProcessScanner` and the `osascript` path in `AppState`. Never throws, never
    /// hangs; any failure (spawn error, unparseable output) reports as `nil` so the caller
    /// leaves its cached belief untouched rather than acting on a guess.
    public static let defaultFlagReader: () -> Bool? = {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["-g"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            // Read stdout BEFORE waiting for exit to avoid deadlock if output > pipe buffer.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard let output = String(data: data, encoding: .utf8) else { return nil }
            return parseSleepDisabled(fromPmsetOutput: output)
        } catch {
            return nil
        }
    }
}
