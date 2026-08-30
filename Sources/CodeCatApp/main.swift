import AppKit
import Dispatch

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate

/// Best-effort in-process safety net for `pmset -a disablesleep 1` (lid mode): that flag
/// is system-wide and survives a crash or `kill -9`, staying set until something clears
/// it. `applicationWillTerminate` only fires on a graceful quit, so it misses a crash,
/// Force Quit, or a signal. The real safety net against those is the LaunchDaemon
/// installed by `scripts/install-lid-mode.sh`, which polls from outside this process and
/// clears the flag whenever no CodeCat process is alive — but a *graceful* SIGTERM/SIGINT
/// (e.g. `pkill -TERM`, launchd stopping the app, a well-behaved kill) should still clear
/// it immediately here rather than waiting on the daemon's poll interval, and `atexit`
/// covers any other normal-exit path that isn't already routed through
/// `applicationWillTerminate`.
///
/// Deliberately a top-level function, not a capturing closure: `atexit` requires a
/// `@convention(c)` function pointer, which cannot capture local context. Referencing the
/// top-level `delegate` global is fine — it is not a capture.
func runShutdownCleanup() {
    delegate.appState.shutdown()
}

atexit(runShutdownCleanup)

// Keep the signal sources alive for the process lifetime (a local variable would be
// deallocated immediately and never fire).
var terminationSignalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT] {
    // Ignore the default disposition first, otherwise the default handler can terminate
    // the process before our DispatchSourceSignal ever gets to run.
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        runShutdownCleanup()
        exit(0)
    }
    source.resume()
    terminationSignalSources.append(source)
}

NSApplication.shared.run()
