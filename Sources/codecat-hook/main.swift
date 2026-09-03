import Foundation
import CodeCatCore

// Claude Code passes the event JSON on stdin. It is forwarded to the app's socket
// with what only this process knows added: the hook is a descendant of `claude`, so
// it can walk its ancestors and find the owning application and the session's
// terminal. App not running, or any error at all → a silent exit 0: the hook has no
// right to get in Claude Code's way.
let input = FileHandle.standardInput.readDataToEndOfFile()
if !input.isEmpty {
    let tree = LiveProcessTree()
    // Start from the PARENT, not from ourselves: the hook lives inside CodeCat.app,
    // and starting at getpid() would record CodeCat itself as the session's owner
    // whenever there is no .app higher up the chain (tmux, screen, ssh, a natively
    // installed claude). By its definition host_pid is the first ANCESTOR inside an
    // .app bundle; the hook is not its own ancestor. Plus a backstop: our own bundle
    // is excluded either way.
    let parent = getppid()
    let host = ProcessTree.host(startingAt: parent, provider: tree,
                                excludingBundlePath: Bundle.main.bundlePath)
    let fields = HookPayload.RouteFields(
        hostPID: host?.pid,
        hostBundlePath: host?.bundlePath,
        // Reading a bundle's Info.plist is one access to a small file; a terminal is
        // recognised by its identifier, not by the bundle's file name.
        hostBundleID: host.flatMap { Bundle(path: $0.bundlePath)?.bundleIdentifier },
        // The tty, though, is looked up from ourselves: the controlling terminal is
        // inherited, so the hook's is the same as its parent's, and starting at
        // getpid() survives the case where the hook was orphaned (getppid() == 1) —
        // otherwise the session would silently lose its tab.
        tty: ProcessTree.tty(startingAt: getpid(), provider: tree),
        // The session's own process is the nearest ancestor named `claude` (usually
        // through the `sh -c` Claude Code launches the hook with). Searched from the
        // parent for the same reason as host: the hook is not its own ancestor. With
        // that pid the app later knows for certain whether the session is alive,
        // instead of guessing from the total number of `claude` processes.
        agentPID: ProcessTree.agent(startingAt: parent, provider: tree))
    let payload = HookPayload.enriched(input, with: fields)
    let sent = HookSocketClient.send(payload, to: CodeCatPaths.socketURL)

    // By design the hook is silent and always exits zero — it has no right to get in
    // Claude Code's way. The side effect was that a failed send left no trace
    // anywhere, and "Claude Code never called the hook" was indistinguishable from
    // "it called it and the app never received it" — from the outside both failures
    // look identical. One line in the shared log closes that gap without breaking
    // anything: writing is still optional and write errors are still silent.
    //
    // writeIfWithinHardLimit rather than write: the hook cannot rotate the file (that
    // would pull it out from under the app's descriptor), so its only defence is to
    // fall silent once the file has grown. That is the case where the app was
    // uninstalled and the hooks stayed in the settings.
    let event = (try? JSONSerialization.jsonObject(with: input) as? [String: Any])
        .flatMap { $0?["hook_event_name"] as? String } ?? "?"
    // The directory may not exist at all — if the app has never been launched. That
    // is exactly the case most worth recording (there is no socket either, and the
    // send has just failed), so the directory is created rather than given up on.
    CodeCatPaths.ensureAppSupportExists()
    let log = DiagnosticLog(url: CodeCatPaths.logURL, source: "hook")
    _ = log.writeIfWithinHardLimit(
        sent ? "sent \(event), \(payload.count) B"
             : "ERROR: \(event) did not reach the socket at \(CodeCatPaths.socketURL.path) "
               + "(app not running?)")
    log.close()
}
exit(0)
