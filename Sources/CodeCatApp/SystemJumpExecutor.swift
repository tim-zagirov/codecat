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

    /// Off-main queue for the permission query alone. Deliberately not `queue`: that
    /// one can be owned by a wedged script, and the query must never wait behind it.
    private let permissionQueue = DispatchQueue(label: "com.codecat.jump.permission")

    /// How many jumps have work still outstanding — a permission query that has not
    /// answered, or a script that has not returned. Counted rather than flagged so a
    /// late finisher cannot clear a deadline belonging to a jump still running.
    /// Main queue only.
    private var outstandingJumps = 0

    /// The latest deadline among the outstanding jumps, on the monotonic clock.
    /// Main queue only.
    private var jumpDeadline: DispatchTime?

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
            let deadlinePassed = jumpDeadline.map { DispatchTime.now() >= $0 } ?? false
            if JumpExecutionPolicy.isBlocked(outstanding: outstandingJumps,
                                             deadlinePassed: deadlinePassed) {
                // An earlier jump is past its deadline with its query or script still
                // outstanding, so the queue it holds is blocked. Queuing behind it
                // would be a silent refusal — the user would click and never hear
                // anything. Say so, and still give them a destination. (Work that is
                // merely still running, inside its deadline, does not block: this jump
                // queues behind it and runs in a moment.)
                let fellBack = activate(pid: pid, bundlePath: bundlePath) == .success
                complete(.failed(JumpMessages.terminalStillBusyDetail(fellBack: fellBack)), completion)
                return
            }

            runTerminalJump(source: source, bundleID: bundleID, pid: pid,
                            bundlePath: bundlePath, completion: completion)
        }
    }

    // MARK: - Running the tab-selection script

    /// One terminal jump, end to end: ask TCC what it will do, then send the script,
    /// under a single deadline that covers *both* steps.
    ///
    /// The permission query needs covering as much as the send does. Its own
    /// documentation says it "may take arbitrarily long to return", and with a consent
    /// panel already up for the same target it can stall outright — so without a
    /// watchdog over it, a second click during that panel would report nothing at all.
    ///
    /// `settled` makes the whole thing a race with exactly one winner — a doubled
    /// alert is its own defect — and, like every other piece of state here, is only
    /// ever touched on the main queue.
    ///
    /// `self` is captured strongly on purpose: these closures always run, so the
    /// retain is temporary rather than a cycle, and a weak capture would let the
    /// completion be dropped entirely if the executor deallocated mid-flight.
    private func runTerminalJump(source: String, bundleID: String, pid: pid_t,
                                 bundlePath: String,
                                 completion: @escaping (JumpOutcome) -> Void) {
        outstandingJumps += 1
        var settled = false
        // Starts true, meaning "not yet known to have been asked". Until TCC answers,
        // nothing has been sent to the terminal, so a watchdog firing in that window
        // must not report that the terminal failed to answer — that is a claim about
        // an app nobody talked to. Only the granted branch, which is the one state
        // that knows the send actually went out, clears it.
        var awaitingConsent = true
        var watchdog: DispatchWorkItem?

        // Marks the underlying work finished — not the same moment as reporting to the
        // user: a jump that timed out is reported while its query or script is still
        // outstanding, and that is exactly what the busy gate needs to know about.
        let finishWork = {
            self.outstandingJumps -= 1
            if self.outstandingJumps == 0 { self.jumpDeadline = nil }
        }

        let settle: (ScriptResult) -> Void = { result in
            guard !settled else { return }
            settled = true
            watchdog?.cancel()
            // Every result other than a hit still owes the user a destination, so the
            // fallback runs first and its *actual* success is what the message reports.
            // `.hostGone` is the exception: activating an app that is gone cannot work,
            // and its message promises nothing.
            let fellBack: Bool
            switch result {
            case .switchedToTab, .hostGone:
                fellBack = false
            case .automationDenied, .tabNotFound, .failed, .timedOut:
                fellBack = self.activate(pid: pid, bundlePath: bundlePath) == .success
            }
            self.complete(result.outcome(fellBack: fellBack), completion)
        }

        // (Re)arms the watchdog. The clock starts short, covering the permission query;
        // it is extended only once TCC says the send will be waiting on a human, so a
        // wedged terminal is still caught quickly.
        func arm(_ timeout: TimeInterval) {
            watchdog?.cancel()
            let item = DispatchWorkItem { settle(.timedOut(awaitingConsent: awaitingConsent)) }
            watchdog = item
            // Monotonic, and the same clock `asyncAfter` uses: a wall clock jumps
            // forward across the system sleep this app's lid mode deliberately allows,
            // which would declare a healthy jump overdue on wake.
            let deadline = DispatchTime.now() + timeout
            jumpDeadline = jumpDeadline.map { max($0, deadline) } ?? deadline
            DispatchQueue.main.asyncAfter(deadline: deadline, execute: item)
        }

        arm(JumpExecutionPolicy.scriptTimeout)

        // Off the main thread, as `AEDeterminePermissionToAutomateTarget`'s own
        // documentation demands. Asking before sending also means an outright refusal
        // is reported without a round trip, and an undecided permission buys the long
        // deadline instead of the short one meant for a wedged terminal.
        permissionQueue.async {
            let status = Self.automationPermissionStatus(forBundleID: bundleID)
            DispatchQueue.main.async {
                guard !settled else { finishWork(); return }
                switch JumpExecutionPolicy.permission(forStatus: status) {
                case .denied:
                    finishWork()
                    settle(.automationDenied)
                case .hostGone:
                    finishWork()
                    settle(.hostGone)
                case .awaitingConsent:
                    awaitingConsent = true
                    arm(JumpExecutionPolicy.consentTimeout)
                    self.send(source, settle: settle, finishWork: finishWork)
                case .granted:
                    awaitingConsent = false
                    self.send(source, settle: settle, finishWork: finishWork)
                }
            }
        }
    }

    private func send(_ source: String,
                      settle: @escaping (ScriptResult) -> Void,
                      finishWork: @escaping () -> Void) {
        queue.async {
            let result = self.runTabScript(source)
            DispatchQueue.main.async {
                finishWork()
                settle(result)
            }
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
        case timedOut(awaitingConsent: Bool)
        case failed(String)

        func outcome(fellBack: Bool) -> JumpOutcome {
            switch self {
            case .switchedToTab: return .switchedToTab
            case .tabNotFound: return .tabNotFound(fellBack: fellBack)
            case .automationDenied: return .automationDenied(fellBack: fellBack)
            case .hostGone: return .hostGone
            case .timedOut(let awaitingConsent):
                return .failed(JumpMessages.failureDetail(
                    JumpMessages.timedOutDetail(awaitingConsent: awaitingConsent),
                    fellBack: fellBack))
            case .failed(let detail):
                return .failed(JumpMessages.failureDetail(detail, fellBack: fellBack))
            }
        }
    }

    /// Runs the tab-selection script and classifies the result.
    ///
    /// A refused automation permission surfaces as AppleScript error -1743
    /// (`errAEEventNotPermitted`), -1742 (`errAETargetAddressNotPermitted`) or -1744
    /// (`errAEEventWouldRequireUserConsent`) — all three need the actionable
    /// permission message rather than a raw AppleScript error; -600 (`procNotFound`)
    /// or -609 (`connectionInvalid`) means the target app went away between routing
    /// and execution.
    private func runTabScript(_ source: String) -> ScriptResult {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            return .failed(JumpMessages.scriptBuildFailedDetail)
        }
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            switch code {
            case -1743, -1744, -1742:
                return .automationDenied
            case -600, -609:
                return .hostGone
            default:
                let message = (error[NSAppleScript.errorMessage] as? String)
                    ?? L10n.f("jump.applescript.code", "code %d", code)
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
              let running = app.bundleURL
        else { return .noSuchApp }
        // Compare paths, not URLs: `URL` equality includes the trailing directory
        // slash, which `bundleURL` carries and `resolvingSymlinksInPath()` drops
        // whenever it actually rewrites the path — so two spellings of the same
        // bundle would compare unequal and tell the user a live session is closed.
        guard Self.canonicalPath(running) == Self.canonicalPath(URL(fileURLWithPath: bundlePath))
        else { return .noSuchApp }
        return app.activate(options: [.activateAllWindows]) ? .success : .refused
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// What TCC would do with an Apple event to this bundle, asked without sending
    /// one and without prompting: `noErr` when already allowed,
    /// `errAEEventNotPermitted` when refused, `errAEEventWouldRequireUserConsent`
    /// when the user has not been asked yet, `procNotFound` when nothing is running
    /// under that identifier.
    ///
    /// A descriptor that cannot be built yields -1744 rather than `noErr`: claiming
    /// "already allowed" would put the short deadline on a send that may still be
    /// waiting for a human.
    ///
    /// Must not be called on the main thread — see the call site.
    private static func automationPermissionStatus(forBundleID bundleID: String) -> OSStatus {
        let descriptor = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let aeDesc = descriptor.aeDesc else { return -1744 }
        return withExtendedLifetime(descriptor) {
            var target = aeDesc.pointee
            return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false)
        }
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
