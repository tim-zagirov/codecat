import AppKit
import CodeCatCore

/// Executes a `JumpRoute` for real: `NSRunningApplication` for bringing an app
/// forward (no permission needed) and `NSAppleScript` for selecting a terminal tab
/// (a one-time automation permission, prompted by macOS on first use).
///
/// `NSAppleScript` is run on a private serial queue — it is not thread-safe and can
/// block for as long as the target app takes to answer, which must never happen on
/// the main thread while the panel is open. Everything else — the state below, the
/// activation calls, the completion — stays on the main queue.
final class SystemJumpExecutor: JumpExecuting {
    /// Serial on purpose: only one `NSAppleScript` runs at a time.
    private let queue = DispatchQueue(label: "com.codecat.jump")

    /// How long a terminal gets to answer before the user is told that it did not.
    /// Selecting a tab is a local Apple event that normally returns in milliseconds;
    /// past a few seconds the terminal is wedged (a stuck ssh, a beachballing tab),
    /// not slow. Eight seconds is long enough not to libel a loaded machine, short
    /// enough that the user is not left staring at nothing — which is the one
    /// outcome the design spec forbids outright.
    private static let scriptTimeout: DispatchTimeInterval = .seconds(8)

    /// True from the moment a script is dispatched until it actually returns, which
    /// may be long after its timeout fired. Main queue only.
    private var scriptInFlight = false

    // MARK: - JumpExecuting

    func perform(_ route: JumpRoute, completion: @escaping (JumpOutcome) -> Void) {
        onMain { self.start(route, completion: completion) }
    }

    private func start(_ route: JumpRoute, completion: @escaping (JumpOutcome) -> Void) {
        switch route {
        case .unavailable(let reason):
            switch reason {
            case .hostGone:
                complete(.hostGone, completion)
            case .noHostRecorded:
                // Honest mapping: the hook never recorded a host for this session, so
                // nothing is known about whether an app is even running. Reporting
                // `.hostGone` here would claim a closed app that may never have been
                // open. The caller filters unavailable routes out before calling, so
                // this path is unreachable today, but it must still be honest.
                complete(.failed(JumpMessages.rowHint(for: .noHostRecorded)), completion)
            }

        case .application(let pid, let bundlePath):
            complete(activationOutcome(pid: pid, bundlePath: bundlePath), completion)

        case .terminalTab(let bundleID, let bundlePath, let pid, let tty):
            guard let source = TerminalJumpScript.script(bundleID: bundleID, tty: tty) else {
                complete(activationOutcome(pid: pid, bundlePath: bundlePath), completion)
                return
            }
            guard !scriptInFlight else {
                // An earlier script has passed its timeout and still has not returned,
                // so the serial queue is blocked. Queuing this jump behind it would be
                // a silent refusal — the user would click and never hear anything.
                // Say so, and still give them a destination.
                let fellBack = activate(pid: pid, bundlePath: bundlePath) == .success
                complete(.failed(JumpMessages.terminalStillBusyDetail(fellBack: fellBack)), completion)
                return
            }
            runScript(source, pid: pid, bundlePath: bundlePath, completion: completion)
        }
    }

    // MARK: - Running the tab-selection script

    /// Runs `source` on the private queue and reports whichever comes first: the
    /// script's own answer, or the timeout. `settled` makes that a race with exactly
    /// one winner — a doubled alert is its own defect — and is only ever touched on
    /// the main queue, like every other piece of state here.
    ///
    /// `self` is captured strongly on purpose: these closures always run, so the
    /// retain is temporary rather than a cycle, and a weak capture would let the
    /// completion be dropped entirely if the executor deallocated mid-flight.
    private func runScript(_ source: String, pid: pid_t, bundlePath: String,
                           completion: @escaping (JumpOutcome) -> Void) {
        scriptInFlight = true
        var settled = false

        let settle: (ScriptResult) -> Void = { result in
            guard !settled else { return }
            settled = true
            // Every result other than a hit still owes the user a destination, so the
            // fallback runs first and its *actual* success is what the message reports.
            // `.hostGone` is excluded: activating an app that is gone cannot work, and
            // its message promises nothing.
            let fellBack: Bool
            switch result {
            case .switchedToTab, .hostGone:
                fellBack = false
            case .automationDenied, .tabNotFound, .failed, .timedOut:
                fellBack = self.activate(pid: pid, bundlePath: bundlePath) == .success
            }
            self.complete(result.outcome(fellBack: fellBack), completion)
        }

        queue.async {
            let result = self.runTabScript(source)
            DispatchQueue.main.async {
                self.scriptInFlight = false
                settle(result)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.scriptTimeout) {
            settle(.timedOut)
        }
    }

    /// What the tab-selection script did, before the fallback is attempted. Separate
    /// from `JumpOutcome` because two of that type's cases record whether the
    /// fallback worked, which is not known yet at this point.
    private enum ScriptResult {
        case switchedToTab
        case tabNotFound
        case automationDenied
        case hostGone
        case timedOut
        case failed(String)

        func outcome(fellBack: Bool) -> JumpOutcome {
            switch self {
            case .switchedToTab: return .switchedToTab
            case .tabNotFound: return .tabNotFound(fellBack: fellBack)
            case .automationDenied: return .automationDenied(fellBack: fellBack)
            case .hostGone: return .hostGone
            case .timedOut: return .failed(JumpMessages.terminalTimedOutDetail)
            case .failed(let detail): return .failed(detail)
            }
        }
    }

    /// Runs the tab-selection script and classifies the result.
    ///
    /// A refused automation permission surfaces as AppleScript error -1743
    /// (`errAEEventNotPermitted`) or -1744 (`errAEEventWouldRequireUserConsent`);
    /// -600 (`procNotFound`) or -609 (`connectionInvalid`) means the target app went
    /// away between routing and execution.
    private func runTabScript(_ source: String) -> ScriptResult {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            return .failed(JumpMessages.scriptBuildFailedDetail)
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
                return .failed(JumpMessages.appleScriptFailureDetail(message))
            }
        }
        switch result.stringValue {
        case TerminalJumpScript.successMarker: return .switchedToTab
        case TerminalJumpScript.notFoundMarker: return .tabNotFound
        default: return .failed(JumpMessages.unexpectedTerminalReplyDetail)
        }
    }

    // MARK: - Bringing an application forward

    /// Result of attempting to bring an already-running app forward, keeping the two
    /// distinct failure modes separate: no such app, versus an app that exists but
    /// declined to activate.
    private enum ActivationResult {
        /// No running application at this pid *is* the app the route was computed
        /// for — either nothing resolves for the pid, or what resolves is something
        /// else entirely.
        case noSuchApp
        /// The app exists but `activate(options:)` returned false. CodeCat runs as an
        /// accessory app (`AppDelegate` sets `.accessory` activation policy) and shows
        /// its panel as a `.nonactivatingPanel`, so CodeCat itself is never frontmost
        /// when a jump fires — precisely the situation where macOS cooperative
        /// activation is most likely to refuse a request.
        case refused
        case success
    }

    /// Activates the app at `pid`, but only after confirming it is still the app the
    /// route was computed for.
    ///
    /// A pid outlives the process that owned it and macOS recycles pids freely, so
    /// `NSRunningApplication(processIdentifier:)` alone will happily hand back an
    /// unrelated program: a session that went quiet hours ago keeps its recorded
    /// `hostPID` (nothing refreshes it while it waits), and activating whatever now
    /// answers would drop the user somewhere random and call it a success. Comparing
    /// the bundle path — and rejecting `.prohibited`, which is what a recycled pid
    /// usually points at — makes a stale pid report the truth instead.
    private func activate(pid: pid_t, bundlePath: String) -> ActivationResult {
        guard let app = NSRunningApplication(processIdentifier: pid),
              app.activationPolicy != .prohibited,
              let running = app.bundleURL?.resolvingSymlinksInPath().standardized,
              running == URL(fileURLWithPath: bundlePath).resolvingSymlinksInPath().standardized
        else { return .noSuchApp }
        return app.activate(options: [.activateAllWindows]) ? .success : .refused
    }

    /// Maps an activation attempt to the outcome reported to the user. A pid that no
    /// longer belongs to the routed app is genuinely `.hostGone`; a refused
    /// activation is `.failed` with its own detail, never conflated with "the app is
    /// no longer running".
    private func activationOutcome(pid: pid_t, bundlePath: String) -> JumpOutcome {
        switch activate(pid: pid, bundlePath: bundlePath) {
        case .success: return .switchedToApplication
        case .noSuchApp: return .hostGone
        case .refused: return .failed(JumpMessages.activationRefusedDetail)
        }
    }

    // MARK: - Queue plumbing

    /// Runs `work` on the main queue, immediately when already there. All of this
    /// executor's state lives on the main queue; callers are the UI, so the immediate
    /// path is the normal one.
    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    /// Delivers the outcome on the main queue, as `JumpExecuting` requires, and never
    /// re-entrantly inside the caller's own frame.
    private func complete(_ outcome: JumpOutcome, _ completion: @escaping (JumpOutcome) -> Void) {
        DispatchQueue.main.async { completion(outcome) }
    }
}
