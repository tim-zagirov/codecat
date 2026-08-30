import AppKit
import CodeCatCore

/// Executes a `JumpRoute` for real: `NSRunningApplication` for bringing an app
/// forward (no permission needed) and `NSAppleScript` for selecting a terminal tab
/// (a one-time automation permission, prompted by macOS on first use).
///
/// `NSAppleScript` is run on a private serial queue — it is not thread-safe and can
/// block for as long as the target app takes to answer, which must never happen on
/// the main thread while the panel is open. The completion always lands back on the
/// main queue.
final class SystemJumpExecutor: JumpExecuting {
    private let queue = DispatchQueue(label: "com.codecat.jump")

    func perform(_ route: JumpRoute, completion: @escaping (JumpOutcome) -> Void) {
        switch route {
        case .unavailable(let reason):
            switch reason {
            case .hostGone:
                finish(.hostGone, completion)
            case .noHostRecorded:
                // Honest mapping: the hook never recorded a host for this session, so
                // nothing is known about whether an app is even running. Reporting
                // `.hostGone` here would claim a closed app that may never have been
                // open. The caller filters unavailable routes out before calling, so
                // this path is unreachable today, but it must still be honest.
                finish(.failed(JumpMessages.rowHint(for: .noHostRecorded)), completion)
            }
        case .application(let pid, _):
            finish(activationOutcome(pid: pid), completion)
        case .terminalTab(let bundleID, _, let pid, let tty):
            guard let source = TerminalJumpScript.script(bundleID: bundleID, tty: tty) else {
                finish(activationOutcome(pid: pid), completion)
                return
            }
            // Strong `self` capture is intentional: this closure runs on `self`'s own
            // serial queue and always completes, so it is a temporary retain, not a
            // cycle. `[weak self]` here would risk dropping `completion` entirely if
            // the executor deallocated between dispatch and execution.
            queue.async {
                let outcome = self.runTabScript(source)
                // Every non-terminal outcome still owes the user a destination: fall
                // back to bringing the app forward, then report what really happened.
                switch outcome {
                case .automationDenied, .tabNotFound, .failed:
                    _ = self.activate(pid: pid)
                default:
                    break
                }
                self.finish(outcome, completion)
            }
        }
    }

    private func finish(_ outcome: JumpOutcome, _ completion: @escaping (JumpOutcome) -> Void) {
        DispatchQueue.main.async { completion(outcome) }
    }

    /// Result of attempting to bring an already-running app forward, keeping the two
    /// distinct failure modes separate: no such process, versus a process that exists
    /// but declined to activate.
    private enum ActivationResult {
        /// No `NSRunningApplication` resolves for this pid — the process is gone.
        case noSuchApp
        /// The app exists but `activate(options:)` returned false. CodeCat runs as an
        /// accessory app (`AppDelegate` sets `.accessory` activation policy) and shows
        /// its panel as a `.nonactivatingPanel`, so CodeCat itself is never frontmost
        /// when a jump fires — precisely the situation where macOS cooperative
        /// activation is most likely to refuse a request.
        case refused
        case success
    }

    private func activate(pid: pid_t) -> ActivationResult {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return .noSuchApp }
        return app.activate(options: [.activateAllWindows]) ? .success : .refused
    }

    /// Maps an activation attempt to the outcome reported to the user. A missing
    /// process is genuinely `.hostGone`; a refused activation is `.failed` with its
    /// own detail, never conflated with "the app is no longer running".
    private func activationOutcome(pid: pid_t) -> JumpOutcome {
        switch activate(pid: pid) {
        case .success: return .switchedToApplication
        case .noSuchApp: return .hostGone
        case .refused: return .failed("не удалось вывести приложение вперёд")
        }
    }

    /// Runs the tab-selection script and classifies the result.
    ///
    /// A refused automation permission surfaces as AppleScript error -1743
    /// (`errAEEventNotPermitted`) or -1744 (`errAEEventWouldRequireUserConsent`);
    /// -600 (`procNotFound`) or -609 (`connectionInvalid`) means the target app went
    /// away between routing and execution.
    private func runTabScript(_ source: String) -> JumpOutcome {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            return .failed("не удалось собрать AppleScript")
        }
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            switch code {
            case -1743, -1744:
                return .automationDenied
            case -600, -609:
                return .hostGone
            default:
                let message = (error[NSAppleScript.errorMessage] as? String) ?? "код \(code)"
                return .failed("AppleScript: \(message)")
            }
        }
        switch result.stringValue {
        case TerminalJumpScript.successMarker: return .switchedToTab
        case TerminalJumpScript.notFoundMarker: return .tabNotFound
        default: return .failed("неожиданный ответ терминала")
        }
    }
}
