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

    /// How many dispatched scripts have not returned yet. Main queue only.
    private var outstandingScripts = 0

    /// The latest deadline among the outstanding scripts, on the monotonic clock —
    /// not `Date`, which jumps forward across system sleep and would declare a
    /// healthy script overdue after the lid was closed (this app's other feature
    /// keeps the Mac awake with the lid shut, so that is not hypothetical).
    /// Main queue only.
    private var scriptDeadline: DispatchTime?

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
            let deadlinePassed = scriptDeadline.map { DispatchTime.now() >= $0 } ?? false
            if JumpExecutionPolicy.isBlocked(outstanding: outstandingScripts,
                                             deadlinePassed: deadlinePassed) {
                // An earlier script has passed its deadline and still has not returned,
                // so the serial queue is blocked. Queuing this jump behind it would be
                // a silent refusal — the user would click and never hear anything.
                // Say so, and still give them a destination. (A script that is merely
                // still running, well inside its deadline, is not blocked: this jump
                // queues behind it and runs in a moment.)
                let fellBack = activate(pid: pid, bundlePath: bundlePath) == .success
                complete(.failed(JumpMessages.terminalStillBusyDetail(fellBack: fellBack)), completion)
                return
            }

            // Ask TCC what it will do *before* sending anything: an outright refusal is
            // reported immediately instead of after a round trip, and — the reason this
            // matters most — a not-yet-decided permission tells us the send will block
            // on the consent panel, so it gets the long deadline rather than the short
            // one meant for a wedged terminal.
            //
            // Off the main thread, as `AEDeterminePermissionToAutomateTarget`'s own
            // documentation demands: it talks to `tccd` and "may take arbitrarily long
            // to return". With a consent panel already up for this target it can stall
            // outright, which on the main thread would freeze the whole UI.
            permissionQueue.async {
                let permission = JumpExecutionPolicy.permission(
                    forStatus: Self.automationPermissionStatus(forBundleID: bundleID))
                DispatchQueue.main.async {
                    self.afterPermission(permission, source: source, pid: pid,
                                         bundlePath: bundlePath, completion: completion)
                }
            }
        }
    }

    /// Acts on TCC's answer, back on the main queue.
    private func afterPermission(_ permission: JumpExecutionPolicy.Permission,
                                 source: String, pid: pid_t, bundlePath: String,
                                 completion: @escaping (JumpOutcome) -> Void) {
        switch permission {
        case .denied:
            let fellBack = activate(pid: pid, bundlePath: bundlePath) == .success
            complete(.automationDenied(fellBack: fellBack), completion)
        case .hostGone:
            complete(.hostGone, completion)
        case .granted, .awaitingConsent:
            runScript(source, pid: pid, bundlePath: bundlePath,
                      timeout: JumpExecutionPolicy.timeout(for: permission),
                      awaitingConsent: permission == .awaitingConsent,
                      completion: completion)
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
                           timeout: TimeInterval, awaitingConsent: Bool,
                           completion: @escaping (JumpOutcome) -> Void) {
        outstandingScripts += 1
        // Keep the furthest deadline: with more than one script outstanding, the queue
        // is only genuinely wedged once the last of them is overdue.
        let deadline = DispatchTime.now() + timeout
        scriptDeadline = scriptDeadline.map { max($0, deadline) } ?? deadline
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
            case .timedOut(let awaitingConsent) where awaitingConsent:
                // The consent panel is still up and the terminal was never asked.
                // Dragging the terminal over that dialog would make it harder to
                // answer — and answering it is the only thing that makes the feature
                // work at all.
                fellBack = false
            case .automationDenied, .tabNotFound, .failed, .timedOut:
                fellBack = self.activate(pid: pid, bundlePath: bundlePath) == .success
            }
            self.complete(result.outcome(fellBack: fellBack), completion)
        }

        queue.async {
            let result = self.runTabScript(source)
            DispatchQueue.main.async {
                self.outstandingScripts -= 1
                if self.outstandingScripts == 0 { self.scriptDeadline = nil }
                settle(result)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: deadline) {
            settle(.timedOut(awaitingConsent: awaitingConsent))
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
