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
        case .unavailable:
            finish(.hostGone, completion)
        case .application(let pid, _):
            finish(activate(pid: pid) ? .switchedToApplication : .hostGone, completion)
        case .terminalTab(let bundleID, _, let pid, let tty):
            guard let source = TerminalJumpScript.script(bundleID: bundleID, tty: tty) else {
                finish(activate(pid: pid) ? .switchedToApplication : .hostGone, completion)
                return
            }
            queue.async { [weak self] in
                guard let self else { return }
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

    private func activate(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return app.activate(options: [.activateAllWindows])
    }

    /// Runs the tab-selection script and classifies the result.
    ///
    /// A refused automation permission surfaces as AppleScript error -1743
    /// (`errAEEventNotPermitted`); -600 (`procNotFound`) means the target app went
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
