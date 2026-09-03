import AppKit
import Combine
import CodeCatCore

/// Owns every long-lived piece of CodeCatCore state and glues it together for the
/// menu-bar UI (Task 12/13 build views on top of this). Not thread-safe — every
/// mutation must happen on the main thread, which holds for all current callers:
/// `HookSocketServer` delivers on `.main`, `TranscriptWatcher` dispatches to
/// `.main` before invoking its callback, and the maintenance `Timer` is scheduled
/// on the main run loop.
final class AppState: ObservableObject {
    let store: SessionStore
    let awayLog = AwayLog()
    /// The only way to learn what happened inside: this is an `LSUIElement` app with
    /// no window and no console, and screen-control tools cannot see it. Before this
    /// file existed, investigating anything meant building an external stand-in on
    /// `CodeCatCore`.
    let log = DiagnosticLog(url: CodeCatPaths.logURL, source: "app")
    let powerManager: PowerManager
    let lidController: LidSleepController
    let jumpExecutor: JumpExecuting

    private var socketServer: HookSocketServer?
    private var watcher: TranscriptWatcher?
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var lastAggregate: AggregateStatus = .sleeping
    /// Shutdown is called twice: from `applicationWillTerminate` and from `atexit` in
    /// main.swift (a backstop for signals). It was visible in the log — two "shutdown"
    /// lines for one exit, 38 ms apart. Harmless in itself, but `resetOnExit()` now
    /// starts a bridge through `caffeinate`, and starting that twice earns nothing.
    private var didShutdown = false

    @Published var keepAwakeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(keepAwakeEnabled, forKey: "keepAwake")
            powerManager.isEnabled = keepAwakeEnabled
            refresh()
        }
    }
    @Published var lidModeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(lidModeEnabled, forKey: "lidMode")
            lidController.isEnabled = lidModeEnabled
            refresh()
        }
    }
    @Published var soundsEnabled: Bool {
        didSet { UserDefaults.standard.set(soundsEnabled, forKey: "sounds") }
    }
    @Published var showMascot: Bool {
        didSet { UserDefaults.standard.set(showMascot, forKey: "showMascot") }
    }
    @Published var hooksInstalled = false

    /// When the mascot entered the state it is showing now. A movement made of several
    /// phases ("stretch — lie down — sleep") has no way of knowing whether its one-shot
    /// part has already played without this reference point, and keeping a counter in
    /// the view itself is not possible: the view is recreated every time the panel
    /// opens and every time the skin changes.
    ///
    /// Compared by `AggregateStatusKey` rather than `AggregateStatus`: the number of
    /// sessions does not affect the movement, and going from "working 1" to
    /// "working 2" must not restart the animation.
    @Published private(set) var statusSince = Date()

    /// Id of the selected skin. Persisted so the choice survives a restart; read
    /// back through `MascotSkins.skin(withID:)`, which falls back to
    /// `MascotSkins.default` for anything it does not recognise.
    @Published var skinID: String {
        didSet { UserDefaults.standard.set(skinID, forKey: "mascotSkin") }
    }

    /// How to show the mascot. Persisted so the choice survives a restart; read back
    /// through `MascotDisplayMode.mode(withID:)`, which falls back to the default mode
    /// for anything it does not recognise.
    @Published var displayMode: MascotDisplayMode {
        didSet { UserDefaults.standard.set(displayMode.rawValue, forKey: "mascotDisplayMode") }
    }

    /// Hide the mascot when there are no sessions at all. Off by default.
    ///
    /// A setting about the MASCOT, not about the island: at first only
    /// `IslandController` read it, and in floating mode the toggle sat dead — switched
    /// on, with the cat still on screen. What the label promises outranks the display
    /// mode.
    ///
    /// The UserDefaults key is deliberately unchanged (`islandHidesWhenIdle`): for
    /// anyone who already turned the toggle on, it has to survive the update. Renaming
    /// the key would silently give them "off".
    @Published var hidesWhenNoSessions: Bool {
        didSet { UserDefaults.standard.set(hidesWhenNoSessions, forKey: "islandHidesWhenIdle") }
    }

    /// Whether the island should be hidden right now under the "hide when nothing is
    /// running" setting.
    ///
    /// The condition is the absence of sessions, not "the cat is asleep". This used to
    /// read `aggregate == .sleeping`, which matched the label exactly as long as every
    /// known session counted as working. Now an open but idle session yields
    /// `.sleeping` — and the island vanished from the screen while sessions existed and
    /// were visible in the panel. What the label promises outranks that: hide when
    /// there is genuinely nothing to hide.
    var mascotShouldHideNow: Bool {
        guard hidesWhenNoSessions else { return false }
        return !store.hasSessions
    }

    /// Whether the "About the assets" credits disclosure in `SkinPickerView` is expanded.
    /// Lives here rather than as local `@State` on that view so toggling it
    /// publishes through `objectWillChange` like every other piece of visible
    /// state: `OverlayController.handleStateChange()` resizes the details panel to
    /// fit its SwiftUI content on that notification, and the credits list — the one
    /// attribution that is a licence obligation (mxmaze, CC BY 4.0) — must never
    /// open clipped inside a panel whose AppKit content rect didn't grow with it.
    @Published var creditsExpanded = false

    var skin: MascotSkin { MascotSkins.skin(withID: skinID) }

    /// The skins the picker may offer: everything in the registry whose sheets are
    /// actually on this machine.
    ///
    /// Not every registered skin ships with the app. Elthen's terms forbid
    /// redistributing the assets, so that sheet is downloaded by whoever builds
    /// CodeCat and is legitimately absent from a plain `git clone` build. A skin
    /// in that state must disappear quietly — a greyed-out tile or an error would
    /// tell the user about a licence problem that is not theirs.
    ///
    /// `@MainActor` because `SpriteSheetStore.shared` is; every caller is a SwiftUI
    /// body, which already is.
    @MainActor
    var availableSkins: [MascotSkin] {
        MascotSkins.all.filter { SpriteSheetStore.shared.hasAssets(for: $0) }
    }

    /// Skins whose failure alert has already been shown. Only the *alert* is
    /// once-per-launch: the view that renders the mascot is rebuilt constantly, and
    /// an alert on every rebuild would be unusable. The revert to the default skin in
    /// `reportSkinLoadFailure` is unconditional and runs every time, regardless of
    /// this set — the drawn cat is not involved here; it is only `MascotView`'s
    /// in-place render fallback for a single failed frame, not something `AppState`
    /// switches to.
    private var reportedSkinFailures: Set<String> = []

    private var lidHelperInstallInFlight = false

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            "keepAwake": true, "lidMode": false, "sounds": false, "showMascot": true,
            "mascotSkin": MascotSkins.default.id,
            "mascotDisplayMode": MascotDisplayMode.default.rawValue,
            "islandHidesWhenIdle": false,
        ])
        keepAwakeEnabled = defaults.bool(forKey: "keepAwake")
        lidModeEnabled = defaults.bool(forKey: "lidMode")
        soundsEnabled = defaults.bool(forKey: "sounds")
        showMascot = defaults.bool(forKey: "showMascot")
        displayMode = MascotDisplayMode.mode(withID: defaults.string(forKey: "mascotDisplayMode"))
        hidesWhenNoSessions = defaults.bool(forKey: "islandHidesWhenIdle")
        // Resolve through `MascotSkins.skin(withID:)` rather than trusting the raw
        // stored string: an id from an older build (e.g. the retired `"drawn"`) must
        // migrate to the default skin here, at read time, so `skinID` and `skin.id`
        // never disagree. Assigning the raw value directly would leave a stale id
        // sitting in `skinID` — rendering the default skin correctly, but with no
        // tile selected in `SkinPickerView` (it compares `skin.id == skinID`) until
        // the user happens to tap one, since `didSet` does not fire on `init`.
        //
        // A stored skin whose sheets are not on this machine gets that same silent
        // migration: it happens when CodeCat was built without running the
        // optional-asset download (Elthen's sheet is not in the repository), and it
        // is not the user's mistake to be told about.
        let storedSkin = MascotSkins.skin(withID: defaults.string(forKey: "mascotSkin") ?? MascotSkins.default.id)
        skinID = SpriteSheetStore.assetsExist(for: storedSkin) ? storedSkin.id : MascotSkins.default.id

        // Read once at startup (see the design spec): a route recorded by a hook
        // before this launch is what makes a session the transcript watcher
        // re-discovers after a restart clickable again, with its real `startedAt`.
        // A missing or corrupt file yields an empty cache silently — nothing here
        // needs to branch on that; `SessionRouteCache.load` already handles it.
        let routeCache = SessionRouteCache(url: CodeCatPaths.routeCacheURL)
        routeCache.load()
        store = SessionStore(routeCache: routeCache)

        jumpExecutor = SystemJumpExecutor()
        powerManager = PowerManager(
            assertion: IOKitSleepAssertion(),
            batteryLevel: { Battery.currentLevelIfOnBattery() })
        lidController = LidSleepController()

        // Reading `self.keepAwakeEnabled`/`self.lidModeEnabled` requires every stored
        // property (including the two `let`s just above) to already have a value, so
        // these assignments must come after both are constructed, not interleaved.
        powerManager.isEnabled = keepAwakeEnabled
        lidController.isEnabled = lidModeEnabled
    }

    func start() {
        CodeCatPaths.ensureAppSupportExists()
        // Rotation here and not only in maintenance: the app may run for days without
        // a restart, but equally it may be launched often and live briefly, in which
        // case the 15-second tick never survives long enough to reach the limit.
        log.rotateIfNeeded()
        let info = Bundle.main.infoDictionary
        log.write("launch — version \(info?["CFBundleShortVersionString"] as? String ?? "?") "
            + "(\(info?["CFBundleVersion"] as? String ?? "?")), display: \(displayMode.rawValue), "
            + "skin: \(skinID)")

        hooksInstalled = HooksInstaller.isInstalled(
            in: try? Data(contentsOf: CodeCatPaths.claudeSettings),
            hookCommand: hookBinaryPath())
        log.write("hooks installed: \(hooksInstalled), binary: \(hookBinaryPath())")

        let server = HookSocketServer(path: CodeCatPaths.socketURL) { [weak self] event in
            guard let self else { return }
            // A line for every event RECEIVED. Together with the line the hook itself
            // writes before sending, it is the only way to tell "Claude Code never
            // called the hook" from "it called it, but it never reached the app": from
            // the outside both failures look identical — the cat simply does not move.
            self.log.write("event \(event.hookEventName) session=\(event.sessionId.prefix(8)) "
                + "cwd=\(event.cwd ?? "—") tty=\(event.tty ?? "—")")
            self.store.apply(hook: event, now: Date())
            self.refresh()
        }
        do {
            try server.start()
            log.write("socket listening: \(CodeCatPaths.socketURL.path)")
        } catch {
            // This used to go to FileHandle.standardError, which is nowhere: the bundle
            // is launched from Finder and has no standard output.
            log.write("ERROR: could not open the socket at \(CodeCatPaths.socketURL.path): \(error)")
        }
        socketServer = server

        let watcher = TranscriptWatcher(root: CodeCatPaths.projectsRoot) { [weak self] activity in
            guard let self else { return }
            self.store.apply(activity: activity)
            self.refresh()
        }
        watcher.start()
        self.watcher = watcher

        // periodic maintenance
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = Date()
            self.store.reconcile(claudeProcessCount: ProcessScanner.claudeProcessCount(), now: now)
            self.store.expireFinished(now: now)
            if !self.hooksInstalled {
                self.store.applyIdleHeuristic(now: now)
            }
            self.powerManager.tick(now: now)
            // Rotation is the app's job alone — see DiagnosticLog: the hook, by renaming
            // the file, would pull it out from under the descriptor already open here.
            self.log.rotateIfNeeded()
            // Reconciles against the real `SleepDisabled` flag on this slower cadence only —
            // `refresh()` below still drives the cheap, cache-only `update(shouldPreventSleep:)`
            // path for the frequent hook-driven case.
            self.lidController.reconcile(shouldPreventSleep: self.powerManager.isHolding)
            self.refresh()
        }

        observeScreenLock()
        store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    /// Runs the scripted `DemoFeed` loop instead of watching anything real.
    ///
    /// Started by `--demo`, in place of `start()`, and it deliberately starts
    /// *nothing* that `start()` does: no socket (a second listener would fight the
    /// installed app for it), no transcript watcher, no power assertion — a demo
    /// must not keep the Mac awake — and no maintenance timer, whose `reconcile`
    /// would notice that none of these sessions has a live process and mark them
    /// all crashed within a minute.
    ///
    /// - Parameter interval: seconds per phase. Four is what the capture script
    ///   uses; the "done" animation is a transition and needs a beat to play.
    /// - Parameter pinnedPhase: hold one phase instead of looping. A screenshot of
    ///   "waiting for you" taken against a four-second loop is a race; this makes it
    ///   a fact.
    func startDemo(interval: TimeInterval = 4, pinnedPhase: DemoFeed.Phase? = nil) {
        log.write("demo mode — no socket, no watcher, no power assertion"
            + (pinnedPhase.map { ", pinned to \($0)" } ?? ""))
        powerManager.isEnabled = false
        lidController.isEnabled = false
        var step = 0
        func apply(_ phase: DemoFeed.Phase) {
            let now = Date()
            for event in DemoFeed.events(for: phase) { store.apply(hook: event, now: now) }
            for activity in DemoFeed.activities(for: phase, now: now) { store.apply(activity: activity) }
            refresh()
        }
        if let pinnedPhase {
            apply(pinnedPhase)
        } else {
            func advance() {
                apply(DemoFeed.phase(atStep: step))
                step += 1
            }
            advance()
            timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in advance() }
        }
        store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func refresh() {
        let agg = store.aggregate
        // Power policy must read `store.anyWorking` (per-session), never `aggregate`
        // (a display-priority value where waiting outranks working) — otherwise one
        // session waiting on the user would wrongly cancel sleep-prevention for other
        // sessions that are still actively working.
        powerManager.update(anyWorking: store.anyWorking, now: Date())
        lidController.update(shouldPreventSleep: powerManager.isHolding)
        notifyTransition(to: agg)
        if AggregateStatusKey(agg) != AggregateStatusKey(lastAggregate) { statusSince = Date() }
        lastAggregate = agg
        objectWillChange.send()
    }

    private func notifyTransition(to agg: AggregateStatus) {
        guard agg != lastAggregate else { return }
        // A state transition is what is visible to the eye as the cat's pose. Recorded
        // next to the hook events, it answers the main question of a manual check: "the
        // cat is showing the wrong thing — did the event not arrive, or did it arrive
        // and the state was computed differently?"
        log.write("state: \(lastAggregate) → \(agg), sessions: \(store.ordered.count)")
        switch agg {
        case .waiting:
            awayLog.record(L10n.t("away.waiting", "an agent is waiting for you"), at: Date())
            if soundsEnabled { NSSound(named: "Purr")?.play() }
        case .done:
            awayLog.record(L10n.t("away.done", "an agent finished its work"), at: Date())
            if soundsEnabled { NSSound(named: "Glass")?.play() }
        case .problem:
            awayLog.record(L10n.t("away.crashed", "a session stopped"), at: Date())
        default:
            break
        }
    }

    private func observeScreenLock() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: .init("com.apple.screenIsLocked"),
                           object: nil, queue: .main) { [weak self] _ in
            self?.awayLog.lock()
        }
        center.addObserver(forName: .init("com.apple.screenIsUnlocked"),
                           object: nil, queue: .main) { [weak self] _ in
            self?.awayLog.unlock()
            self?.objectWillChange.send()
        }
    }

    /// Resolves the path to the `codecat-hook` binary next to the currently
    /// running executable. Works both for `swift run CodeCatApp` (binary sits in
    /// `.build/.../debug/` alongside `codecat-hook`, built by the same package)
    /// and for a packaged `.app` bundle, provided the bundling step places
    /// `codecat-hook` next to `CodeCatApp` inside `Contents/MacOS/`.
    func hookBinaryPath() -> String {
        URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .appendingPathComponent("codecat-hook").path
    }

    func installHooksIfNeeded() {
        let existing: Data?
        switch HooksInstaller.readSettings(at: CodeCatPaths.claudeSettings) {
        case .notFound:
            existing = nil
        case .data(let data):
            existing = data
        case .unreadable:
            // Never fall through to `nil` here: `HooksInstaller.install` treats `nil` as
            // an empty document (`{}`), which is correct for a genuine first install but
            // would otherwise let a transient read failure destroy the user's real
            // settings (permission allowlist, MCP config, model settings, other hooks) by
            // writing a document containing only CodeCat's hooks over it.
            let alert = NSAlert()
            alert.messageText = L10n.t("hooks.install.failed.title", "Couldn't install the hooks")
            alert.informativeText = L10n.f("hooks.settings.unreadable",
                "Couldn't read the settings file %@. Check its permissions and try again.",
                CodeCatPaths.claudeSettings.path)
            alert.runModal()
            return
        }

        guard let updated = try? HooksInstaller.install(
            into: existing, hookCommand: hookBinaryPath()) else {
            let alert = NSAlert()
            alert.messageText = L10n.t("hooks.install.failed.title", "Couldn't install the hooks")
            alert.informativeText = L10n.f("hooks.settings.unwritable",
                "Couldn't update the settings file %@. Check that the file is valid.",
                CodeCatPaths.claudeSettings.path)
            alert.runModal()
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: CodeCatPaths.claudeSettings.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            // .atomic: a crash or I/O error mid-write must never leave a truncated
            // settings file — write-to-temp-then-rename either lands the whole new
            // document or leaves the old one untouched.
            try updated.write(to: CodeCatPaths.claudeSettings, options: .atomic)
            hooksInstalled = true
        } catch {
            let alert = NSAlert()
            alert.messageText = L10n.t("hooks.install.failed.title", "Couldn't install the hooks")
            alert.informativeText = L10n.f("hooks.settings.write.error", "Couldn't write to %@: %@",
                CodeCatPaths.claudeSettings.path, error.localizedDescription)
            alert.runModal()
        }
    }

    /// Removes CodeCat's hooks from `~/.claude/settings.json`.
    ///
    /// The mirror of `installHooksIfNeeded()` and a precondition for honest
    /// uninstallation: without it, a utility deleted from /Applications would leave
    /// five entries in Claude Code's settings calling a binary that no longer exists —
    /// on every event of every session. `HooksInstaller.remove` clears only entries
    /// carrying our own command, leaving other people's hooks and every other key
    /// untouched.
    ///
    /// It asks for confirmation: this edits the user's settings file, not our own state.
    func removeHooks() {
        let existing: Data?
        switch HooksInstaller.readSettings(at: CodeCatPaths.claudeSettings) {
        case .notFound:
            // No file means nothing to remove, and that is not an error. The flag is
            // still cleared: with no settings, our hooks are not in them either.
            hooksInstalled = false
            return
        case .data(let data):
            existing = data
        case .unreadable:
            // Exactly the same caution as on install, and for the same reason: `remove`
            // treats nil as an empty document, and writing that result would wipe the
            // user's real settings entirely.
            presentHooksAlert(
                title: L10n.t("hooks.remove.failed.title", "Couldn't remove the hooks"),
                message: L10n.f("hooks.settings.unreadable",
                    "Couldn't read the settings file %@. Check its permissions and try again.",
                    CodeCatPaths.claudeSettings.path))
            return
        }

        let confirm = NSAlert()
        confirm.messageText = L10n.t("hooks.remove.confirm.title", "Remove CodeCat's hooks?")
        confirm.informativeText = L10n.f("hooks.remove.confirm.body",
            "CodeCat's entries for these events will be removed from %1$@: %2$@. "
            + "Other hooks and the rest of your settings are left alone."
            + "\n\nWithout hooks the cat keeps working, but it learns about session "
            + "changes late — from transcripts rather than from events.",
            CodeCatPaths.claudeSettings.path,
            HooksInstaller.events.joined(separator: ", "))
        confirm.addButton(withTitle: L10n.t("hooks.remove.confirm.button", "Remove"))
        confirm.addButton(withTitle: L10n.t("button.cancel", "Cancel"))
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        guard let updated = try? HooksInstaller.remove(
            from: existing, hookCommand: hookBinaryPath()) else {
            presentHooksAlert(
                title: L10n.t("hooks.remove.failed.title", "Couldn't remove the hooks"),
                message: L10n.f("hooks.settings.unwritable",
                    "Couldn't update the settings file %@. Check that the file is valid.",
                    CodeCatPaths.claudeSettings.path))
            return
        }

        do {
            // .atomic for the same reason as on install: an interrupted write has no
            // right to leave the user with a truncated settings.json.
            try updated.write(to: CodeCatPaths.claudeSettings, options: .atomic)
            hooksInstalled = false
        } catch {
            presentHooksAlert(
                title: L10n.t("hooks.remove.failed.title", "Couldn't remove the hooks"),
                message: L10n.f("hooks.settings.write.error", "Couldn't write to %@: %@",
                    CodeCatPaths.claudeSettings.path, error.localizedDescription))
        }
    }

    private func presentHooksAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    // MARK: - Closed-lid mode

    /// Single entry point for the closed-lid toggle, from both the menu bar and the
    /// details panel. Turning it on when the one-time helper (`scripts/install-lid-mode.sh`,
    /// see `LidSleepController`) is not yet installed kicks off that install asynchronously
    /// (it prompts for an administrator password via `osascript`) — `lidModeEnabled` only
    /// flips to `true` once the install actually took effect, never optimistically. Every
    /// outcome other than a clean success is reported with an `NSAlert`. Turning the mode
    /// off is synchronous, never prompts, and always succeeds (it just clears the flag via
    /// `LidSleepController`).
    ///
    /// Closed-lid mode is a strictly stronger form of keep-awake — it is meaningless on its
    /// own — so turning it on also turns on `keepAwakeEnabled`, updating that toggle's own
    /// published state so the menu and the details panel both show it on.
    func requestLidModeChange(to newValue: Bool) {
        guard newValue != lidModeEnabled else { return }
        guard newValue else {
            lidModeEnabled = false
            return
        }
        if LidSleepController.isHelperInstalled {
            enableLidModeNowThatHelperIsReady()
            return
        }
        guard !lidHelperInstallInFlight else { return }
        guard let scriptURL = locateScript("install-lid-mode.sh") else {
            presentLidAlert(
                title: L10n.t("lid.script.missing.title", "Installer script not found"),
                message: L10n.t("lid.script.missing.body",
                    "Run it yourself: sudo bash scripts/install-lid-mode.sh"))
            return
        }
        lidHelperInstallInFlight = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (status, output) = Self.runLidInstallScript(at: scriptURL)
            let outcome = LidHelperInstall.classify(status: status, output: output)
            DispatchQueue.main.async {
                guard let self else { return }
                self.lidHelperInstallInFlight = false
                self.handleLidInstallOutcome(outcome)
            }
        }
    }

    private func enableLidModeNowThatHelperIsReady() {
        keepAwakeEnabled = true
        lidModeEnabled = true
    }

    private func handleLidInstallOutcome(_ outcome: LidHelperInstall.Outcome) {
        switch outcome {
        case .success:
            // Re-check rather than assume: a successful `osascript` exit only means the
            // script ran to completion, not that the sudoers rule actually landed.
            if LidSleepController.isHelperInstalled {
                enableLidModeNowThatHelperIsReady()
            } else {
                presentLidAlert(
                    title: L10n.t("lid.enable.failed.title", "Couldn't turn on closed-lid mode"),
                    message: L10n.t("lid.enable.failed.body",
                        "The installer finished but the rule still isn't there. Try again, or "
                        + "install it yourself: sudo bash scripts/install-lid-mode.sh"))
            }
        case .cancelled:
            presentLidAlert(
                title: L10n.t("lid.setup.needed.title", "One-time setup needed"),
                message: L10n.t("lid.setup.needed.body",
                    "Closed-lid mode needs an administrator password once. You can turn it on "
                    + "later — try again when you're ready to enter it."))
        case .failed(let detail):
            presentLidAlert(
                title: L10n.t("lid.install.failed.title", "Setup didn't finish"),
                message: L10n.f("lid.install.failed.body",
                    "The installer exited with an error (%@). Try installing it yourself: "
                    + "sudo bash scripts/install-lid-mode.sh", detail))
        }
    }

    private func presentLidAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    /// Runs the installer via `osascript ... with administrator privileges` and returns its
    /// exit status plus combined stdout/stderr for diagnosing a failure. Never called on the
    /// main thread — it blocks for as long as the user takes to respond to the password
    /// prompt.
    private static func runLidInstallScript(at scriptURL: URL) -> (status: Int32, output: String) {
        let osa = LidHelperInstall.appleScript(forScriptAt: scriptURL.path)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", osa]
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        do {
            try task.run()
        } catch {
            return (-1, L10n.f("lid.osascript.failed", "Couldn't run osascript: %@",
                               error.localizedDescription))
        }
        // Drain both pipes BEFORE waiting for exit. Waiting first deadlocks if the
        // child fills a 64 KB pipe buffer: it blocks writing while we block waiting.
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        var combined = String(data: outData, encoding: .utf8) ?? ""
        let errString = String(data: errData, encoding: .utf8) ?? ""
        if !errString.isEmpty {
            combined += combined.isEmpty ? errString : "\n\(errString)"
        }
        return (task.terminationStatus, combined)
    }

    /// Resolves `name` next to the currently running executable: inside `Contents/Resources/`
    /// for a packaged `.app` bundle, or under the repo's `scripts/` directory for
    /// `swift run CodeCatApp` from the repo root.
    private func locateScript(_ name: String) -> URL? {
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath().deletingLastPathComponent()
        let candidates = [
            exeDir.appendingPathComponent("../Resources/\(name)"),  // inside the .app
            exeDir.appendingPathComponent("../../../scripts/\(name)"), // swift run from the root
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func shutdown() {
        guard !didShutdown else { return }
        didShutdown = true
        log.write("shutdown")
        lidController.resetOnExit()
        socketServer?.stop()
        watcher?.stop()
        timer?.invalidate()
        // Last: everything above may still want to write something.
        log.close()
    }

    // MARK: - Jumping to a session

    /// Where a click on this session's row would send the user. Cheap enough to call
    /// during a view body: one `kill(pid, 0)` per visible row.
    func route(for session: Session) -> JumpRoute {
        SessionRouter.route(for: session, isHostRunning: SessionRouter.isProcessRunning)
    }

    /// Executes the jump and reports the outcome. Successful jumps say nothing — the
    /// user is already looking at the destination; everything else gets an alert, so
    /// there are no silent refusals.
    func jump(to session: Session) {
        let route = route(for: session)
        if case .unavailable(let reason) = route {
            // The route was computed fresh just now, at click time, so this can
            // legitimately differ from what the row showed a moment ago (e.g. the
            // host quit in between). `.hostGone` is a real, reportable failure —
            // staying silent here would be a dead click on a row that looked
            // clickable. `.noHostRecorded` is correctly silent: `route(for:)` never
            // makes such a row clickable in the first place (see
            // `DetailsPanelView.hasRoute`), so this branch is unreachable for it
            // today, but honoring it explicitly keeps that guarantee visible here
            // too rather than relying only on the view layer.
            guard reason == .hostGone, let message = JumpMessages.alert(for: .hostGone) else { return }
            presentJumpAlert(message)
            return
        }
        jumpExecutor.perform(route) { [weak self] outcome in
            guard let message = JumpMessages.alert(for: outcome) else { return }
            self?.presentJumpAlert(message)
        }
    }

    /// Brings CodeCat to the front immediately before presenting a jump-failure
    /// alert, then shows it. Required because CodeCat runs as an accessory app
    /// (`.accessory` activation policy, set in `AppDelegate`) and is never the
    /// active application when a jump fires — and on most paths that reach this
    /// method, `SystemJumpExecutor` has just tried to activate the *target* app
    /// (recoverable failures fall back to bringing it forward before reporting;
    /// `.hostGone` does not, and a refused activation tried and failed). Without
    /// activating CodeCat first, `NSAlert.runModal()` would present a window that
    /// never comes to the front: the user sees the target app appear and nothing
    /// else, i.e. a silent failure. `automationDenied` is the very first terminal
    /// jump every user will make, so this path matters from the start.
    ///
    /// Only ever called from a jump-failure path — never on a successful jump,
    /// which stays silent and must not steal focus back from the app the user was
    /// just sent to.
    /// Activation alone is not enough to guarantee that: `NSApp.activate()` and the
    /// executor's activation of the target app are both asynchronous *requests* to
    /// the window server, issued in that order, and either can be declined or land
    /// second. So the alert's own window is raised explicitly as well — that part
    /// depends on no ordering and cannot be refused.
    private func presentJumpAlert(_ message: (title: String, body: String)) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = message.title
        alert.informativeText = message.body
        alert.window.level = .modalPanel
        alert.window.orderFrontRegardless()
        alert.runModal()
    }

    /// Reports a skin whose sheets could not be read, and switches back to the
    /// default skin. Told with an alert rather than a line in the details panel
    /// because the panel may well be closed — this project's rule is that there are
    /// no silent refusals.
    ///
    /// Only the alert is once per launch (see `reportedSkinFailures`'s doc comment);
    /// the revert to `MascotSkins.default` runs unconditionally, every time this is
    /// called. Selecting the same broken skin a second time still needs `skinID`
    /// reverted and persisted — otherwise the second selection would return at the
    /// old guard before reverting, leaving `skinID` pointing at a skin that fails to
    /// load, silently persisted to `UserDefaults`, with the picker's selection
    /// border drawn around a skin the mascot isn't actually showing.
    ///
    /// If `MascotSkins.default` is itself the broken skin, this still terminates
    /// rather than looping: the revert assigns `skinID` its *current* value (`skin.id
    /// == MascotSkins.default.id` already), so `didSet` persists the same string and
    /// nothing about the view's `skin.id` changes. `MascotView`'s `.task(id: skin.id)`
    /// only restarts when that id actually changes, so it does not re-fire and call
    /// back in here — the `reportedSkinFailures` guard below is a second, independent
    /// backstop against repeating the alert, not what actually stops the recursion.
    func reportSkinLoadFailure(_ skin: MascotSkin) {
        if skinID == skin.id { skinID = MascotSkins.default.id }
        guard reportedSkinFailures.insert(skin.id).inserted else { return }
        // Same activation dance as `presentJumpAlert`: CodeCat is an accessory app
        // and its windows do not come forward on their own.
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = L10n.f("skin.load.failed.title", "Couldn't load the %@ skin", skin.name)
        // Must not claim which skin ended up on screen: if the whole `Skins`
        // directory is missing, the default skin's own sheets fail to load too, and
        // the user is looking at `CatView`'s drawn-cat fallback, not the default
        // skin. Naming only the skin that failed and saying "switched" keeps
        // this true in both cases.
        alert.informativeText = L10n.t("skin.load.failed.body",
            "Its files couldn't be read. Switched to another skin.")
        alert.window.level = .modalPanel
        alert.window.orderFrontRegardless()
        alert.runModal()
    }
}
