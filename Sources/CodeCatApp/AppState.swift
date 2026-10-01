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
    /// When the last hook event arrived: the Claude Code pane's "last event 4 s ago",
    /// the one sign that the hooks really reach the app. Not published — every event
    /// ends in `refresh()` anyway, and the pane redraws the age once a second.
    private(set) var lastHookEventAt: Date?
    /// Running the scripted `--demo` feed instead of real sessions (`startDemo`).
    private(set) var isDemo = false
    /// Demo sessions drawn as having no route, for the "no route" capture.
    private var demoUnroutable: Set<String> = []

    /// The open island's footer (§5.5). `PowerManager` is not observable, so the
    /// state is recomputed here on every `refresh()` — hook events and the 15 s
    /// tick — and published.
    @Published private(set) var powerFooter = PowerFooter.none
    /// "Not now" on the first-run card: hidden until the next launch (§5.6).
    @Published var firstRunDismissed = false
    /// `--demo-lid`: the demo claims closed-lid mode is on, for the footer capture,
    /// without writing the real setting.
    var demoLidOn = false

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
    /// back through `registry.skin(withID:)`, which falls back to
    /// `MascotSkins.default` for anything it does not recognise — a built-in id
    /// that was renamed, or a pet id whose folder is no longer on disk.
    @Published var skinID: String {
        didSet { UserDefaults.standard.set(skinID, forKey: "mascotSkin") }
    }

    /// Built-in skins plus the pets found on disk. Rebuilt at launch and every time
    /// the skin picker appears (`rescanPets`); a scan is a few directory listings.
    @Published private(set) var registry = SkinRegistry()

    /// Folders already reported in the log this launch, so a broken pet is named
    /// once rather than on every rescan.
    private var reportedPetProblems: Set<URL> = []

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

    /// Whether a session's row shows what the user asked it for. On by default: the
    /// row exists to answer "what is this session working on", and a fix shipped
    /// switched off is not a fix.
    ///
    /// It is a setting at all because the text is the user's own words, and there are
    /// moments — a demo, a screen recording, a shared call — when a project someone
    /// else should not read is on screen. The always-on-screen surface never shows it
    /// (the compact island carries the cat and the right wing's live data, nothing
    /// else); it appears only where the user opened something: the floating panel's
    /// rows, and the open island's cards — their task line, step line, handoff
    /// summary and chips, and the words in a waiting or crashed card's reason line.
    @Published var showsTaskText: Bool {
        didSet { UserDefaults.standard.set(showsTaskText, forKey: "showTaskText") }
    }

    /// How long the cursor rests on the island before it opens — spec §5.1 (0.4's
    /// fixed 300 ms dwell, made adjustable). The switch arrives with the Settings
    /// window in Part 3; the value is read from here from now on.
    @Published var hoverDelay: TimeInterval {
        didSet { UserDefaults.standard.set(hoverDelay, forKey: "hoverDelay") }
    }

    /// Spec §8 Alerts — which of §6.1's self-opening peeks the user wants. All on by
    /// default: a peek is the product's answer to "an agent needs you".
    @Published var peekOnWaiting: Bool {
        didSet { UserDefaults.standard.set(peekOnWaiting, forKey: "peekOnWaiting") }
    }
    @Published var peekOnCrash: Bool {
        didSet { UserDefaults.standard.set(peekOnCrash, forKey: "peekOnCrash") }
    }
    @Published var peekOnDone: Bool {
        didSet { UserDefaults.standard.set(peekOnDone, forKey: "peekOnDone") }
    }
    /// Spec §6.2: the island steps aside while a full-screen app covers the notch
    /// screen; a waiting or crashed peek still shows.
    @Published var hidesInFullScreen: Bool {
        didSet { UserDefaults.standard.set(hidesInFullScreen, forKey: "hideInFullScreen") }
    }
    /// Spec §6.2: no peeks while the screen is locked, one summary after. The
    /// controllers read it; `AwayLog` and its "While you were away" section are gone.
    @Published private(set) var screenIsLocked = false

    var peekSettings: PeekSettings {
        PeekSettings(onWaiting: peekOnWaiting, onCrash: peekOnCrash, onDone: peekOnDone)
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

    var skin: MascotSkin { registry.skin(withID: skinID) }

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
        registry.installed.filter { SpriteSheetStore.shared.hasAssets(for: $0) }
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
            "islandHidesWhenIdle": false, "showTaskText": true,
            "hoverDelay": Motion.hoverDelayDefault,
            "peekOnWaiting": true, "peekOnCrash": true, "peekOnDone": true, "hideInFullScreen": true,
        ])
        keepAwakeEnabled = defaults.bool(forKey: "keepAwake")
        lidModeEnabled = defaults.bool(forKey: "lidMode")
        soundsEnabled = defaults.bool(forKey: "sounds")
        showMascot = defaults.bool(forKey: "showMascot")
        displayMode = MascotDisplayMode.mode(withID: defaults.string(forKey: "mascotDisplayMode"))
        hidesWhenNoSessions = defaults.bool(forKey: "islandHidesWhenIdle")
        showsTaskText = defaults.bool(forKey: "showTaskText")
        hoverDelay = min(Motion.hoverDelayRange.upperBound,
                         max(Motion.hoverDelayRange.lowerBound, defaults.double(forKey: "hoverDelay")))
        peekOnWaiting = defaults.bool(forKey: "peekOnWaiting")
        peekOnCrash = defaults.bool(forKey: "peekOnCrash")
        peekOnDone = defaults.bool(forKey: "peekOnDone")
        hidesInFullScreen = defaults.bool(forKey: "hideInFullScreen")
        // Scan for pets before resolving the stored skin, so an imported id is
        // recognised on the very launch that brings its folder back (or takes it
        // away). `scanPets` is `static` and takes `reportedPetProblems` `inout`
        // rather than being an instance method, because at this point in `init`
        // not every stored property has a value yet, and an instance method may
        // not be called on `self` until they all do; `log` and
        // `reportedPetProblems` are safe to pass here because both are given their
        // values inline, at declaration, rather than later in this initialiser.
        // The result is kept in a local rather than read back out of `registry`
        // immediately below: `registry` is `@Published`, so reading it goes
        // through the wrapper's synthesized getter, which — like any other
        // instance-property read — is not allowed until every stored property has
        // a value, and several (`store`, `powerManager`, ...) still don't at this
        // point.
        let freshRegistry = Self.scanPets(reporting: &reportedPetProblems, log: log)
        registry = freshRegistry

        // Resolve through the freshly scanned registry rather than trusting the raw
        // stored string: an id from an older build (e.g. the retired `"drawn"`) must
        // migrate to the default skin here, at read time, so `skinID` and `skin.id`
        // never disagree. Assigning the raw value directly would leave a stale id
        // sitting in `skinID` — rendering the default skin correctly, but with no
        // tile selected in `SkinGrid` (it compares `skin.id == skinID`) until
        // the user happens to tap one, since `didSet` does not fire on `init`.
        //
        // A stored skin whose sheets are not on this machine gets that same silent
        // migration: it happens when CodeCat was built without running the
        // optional-asset download (Elthen's sheet is not in the repository), and it
        // is not the user's mistake to be told about.
        let storedSkin = freshRegistry.skin(withID: defaults.string(forKey: "mascotSkin") ?? MascotSkins.default.id)
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
            self.lastHookEventAt = Date()
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
    /// - Parameter pin: hold one scene instead of looping. A screenshot of
    ///   "waiting for you" taken against a four-second loop is a race; this makes it
    ///   a fact. `.problem` is reachable only this way — see `DemoFeed.Pin`.
    /// - Parameter hooksInstalled: false for the first-run capture: the demo
    ///   otherwise claims hooks are installed, or every capture would show the setup
    ///   card.
    /// - Parameter unroutable: session ids to draw with no route, for the "no
    ///   route" capture.
    func startDemo(interval: TimeInterval = 4, pin: DemoFeed.Pin? = nil,
                   hooksInstalled: Bool = true, unroutable: Set<String> = [], peek: DemoFeed.PeekDemo? = nil) {
        log.write("demo mode — no socket, no watcher, no power assertion, no route cache"
            + (pin.map { ", pinned to \($0)" } ?? ""))
        isDemo = true
        self.hooksInstalled = hooksInstalled
        lastHookEventAt = Date().addingTimeInterval(-4)
        demoUnroutable = unroutable
        // The demo must leave no trace in the user's state — see
        // `SessionStore.detachRouteCache`.
        store.detachRouteCache()
        powerManager.isEnabled = false
        lidController.isEnabled = false
        var step = 0
        func apply(_ phase: DemoFeed.Phase) {
            let now = Date()
            for event in DemoFeed.events(for: phase) { store.apply(hook: event, now: now) }
            for activity in DemoFeed.activities(for: phase, now: now) { store.apply(activity: activity) }
            refresh()
        }
        if let pin {
            DemoFeed.apply(pin, to: store, now: Date())
            refresh()
        } else {
            func advance() {
                apply(DemoFeed.phase(atStep: step))
                step += 1
            }
            advance()
            timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in advance() }
        }
        if let peek {
            // After the island has been built on the pinned scene: the peek is the
            // change, and the controller's first session list is its baseline.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                if peek == .away { return self.demoAway() }
                DemoFeed.apply(peek, to: self.store, now: Date())
                self.refresh()
            }
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
        updatePowerFooter(now: Date())
        notifyTransition(to: agg)
        if AggregateStatusKey(agg) != AggregateStatusKey(lastAggregate) { statusSince = Date() }
        lastAggregate = agg
        objectWillChange.send()
    }

    private func updatePowerFooter(now: Date) {
        // The demo holds no assertion (a demo must not keep the Mac awake), so it
        // shows what the real app would: awake while anything works.
        let footer = PowerFooter.make(
            isHolding: isDemo ? store.anyWorking : powerManager.isHolding,
            releaseDeadline: isDemo ? nil : powerManager.releaseDeadline,
            workingCount: store.workingCount,
            lidModeOn: isDemo ? demoLidOn : lidModeEnabled,
            now: now)
        if footer != powerFooter { powerFooter = footer }
    }

    /// The crashed card's ×: the row goes, and the aggregate with it.
    func dismiss(_ session: Session) {
        store.dismiss(id: session.id)
        refresh()
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
            if soundsEnabled { NSSound(named: "Purr")?.play() }
        case .done:
            if soundsEnabled { NSSound(named: "Glass")?.play() }
        default:
            break
        }
    }

    private func observeScreenLock() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: .init("com.apple.screenIsLocked"),
                           object: nil, queue: .main) { [weak self] _ in
            self?.screenIsLocked = true
        }
        center.addObserver(forName: .init("com.apple.screenIsUnlocked"),
                           object: nil, queue: .main) { [weak self] _ in
            self?.screenIsLocked = false
        }
    }

    /// `--demo-peek=away`: the screen "locks", two sessions change, it "unlocks" — the
    /// summary peek, without locking the real screen.
    func demoAway() {
        screenIsLocked = true
        DemoFeed.apply(.away, to: store, now: Date())
        refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.screenIsLocked = false }
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
        // Each dialog below activates CodeCat; when the flow ends, the user is put back
        // where they were — unless they are in the Settings window (`FocusReturn`).
        FocusReturn.remember()
        defer { FocusReturn.handBack() }
        guard !isDemo else { return presentDemoHooksAlert() }
        // This edits the user's own settings file, so it asks first — the mirror of
        // `removeHooks`. On Cancel nothing is read, merged or written.
        let confirm = NSAlert()
        confirm.messageText = L10n.t("hooks.install.confirm.title",
            "Let CodeCat watch your Claude Code sessions?")
        confirm.informativeText = L10n.f("hooks.install.confirm.body",
            "CodeCat will add itself to %1$@ as a handler for these events: %2$@. "
            + "Everything else in that file — your permissions, MCP servers and other "
            + "hooks — is left exactly as it is."
            + "\n\nYou can undo this any time from Settings › Claude Code › Remove hooks….",
            CodeCatPaths.claudeSettings.path,
            HooksInstaller.events.joined(separator: ", "))
        confirm.addButton(withTitle: L10n.t("hooks.install.confirm.button", "Set up"))
        confirm.addButton(withTitle: L10n.t("button.cancel", "Cancel"))
        guard runInFront(confirm) == .alertFirstButtonReturn else { return }

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
            runInFront(alert)
            return
        }

        guard let updated = try? HooksInstaller.install(
            into: existing, hookCommand: hookBinaryPath()) else {
            let alert = NSAlert()
            alert.messageText = L10n.t("hooks.install.failed.title", "Couldn't install the hooks")
            alert.informativeText = L10n.f("hooks.settings.unwritable",
                "Couldn't update the settings file %@. Check that the file is valid.",
                CodeCatPaths.claudeSettings.path)
            runInFront(alert)
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
            // Success feedback: the button just vanishing (M7) left the user unsure
            // whether anything happened. Say plainly what to expect, including the one
            // surprise — already-open sessions need a restart to be seen.
            presentHooksAlert(
                title: L10n.t("hooks.install.done.title", "CodeCat is watching"),
                message: L10n.t("hooks.install.done.body",
                    "New Claude Code sessions appear in the list. Sessions that are "
                    + "already open need to be restarted before CodeCat sees them."))
        } catch {
            let alert = NSAlert()
            alert.messageText = L10n.t("hooks.install.failed.title", "Couldn't install the hooks")
            alert.informativeText = L10n.f("hooks.settings.write.error", "Couldn't write to %@: %@",
                CodeCatPaths.claudeSettings.path, error.localizedDescription)
            runInFront(alert)
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
        // Each dialog below activates CodeCat; when the flow ends, the user is put back
        // where they were — unless they are in the Settings window (`FocusReturn`).
        FocusReturn.remember()
        defer { FocusReturn.handBack() }
        guard !isDemo else { return presentDemoHooksAlert() }
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
        guard runInFront(confirm) == .alertFirstButtonReturn else { return }

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

    /// The demo is a debug build run for captures, and `hookBinaryPath()` points into
    /// `.build/debug/`: a confirmed Connect… on the first-run card added a second set
    /// of hooks calling that binary to the user's real settings (install only merges
    /// an identical command), and Remove took out the installed app's. So in the demo
    /// neither reads nor writes the file; the alert says why nothing happened.
    private func presentDemoHooksAlert() {
        presentHooksAlert(
            title: L10n.t("hooks.demo.title", "The demo leaves Claude Code alone"),
            message: L10n.f("hooks.demo.body",
                "CodeCat is running its demo, so %@ is not read or changed. "
                + "Connect from the CodeCat you use every day.",
                CodeCatPaths.claudeSettings.path))
    }

    private func presentHooksAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        runInFront(alert)
    }

    /// Runs `alert` in front of everything. The hooks' dialogs are asked for from the
    /// island's Connect…, the floating panel or the status-bar menu, and none of them
    /// activates CodeCat, an accessory app: without this, `runModal()` put the confirm
    /// behind the frontmost app's windows and the click on Connect… seemed to do
    /// nothing, while the app sat blocked in the modal. Activating is fine here — the
    /// user asked for this window (spec §8) — and the window is also raised itself,
    /// for the reason `presentJumpAlert` gives.
    @discardableResult
    private func runInFront(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate()
        alert.window.level = .modalPanel
        alert.window.orderFrontRegardless()
        return alert.runModal()
    }

    // MARK: - Closed-lid mode

    /// Single entry point for the closed-lid toggle in the Power pane. Turning it on
    /// when the one-time helper (`scripts/install-lid-mode.sh`, see
    /// `LidSleepController`) is not yet installed kicks off that install asynchronously
    /// (it prompts for an administrator password via `osascript`) — `lidModeEnabled` only
    /// flips to `true` once the install actually took effect, never optimistically. Every
    /// outcome other than a clean success is reported with an `NSAlert`. Turning the mode
    /// off is synchronous, never prompts, and always succeeds (it just clears the flag via
    /// `LidSleepController`).
    ///
    /// Closed-lid mode is a strictly stronger form of keep-awake — it is meaningless on its
    /// own — so turning it on also turns on `keepAwakeEnabled`, updating that toggle's own
    /// published state so the Power pane shows it on.
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
        // Nothing has changed yet: `lidModeEnabled` is still false at this point (the guards
        // above only ran because the toggle asked to go on), so bailing out here — before any
        // install work — leaves the toggle visibly off with no state to revert. Spell out what
        // the admin prompt is about to install before we ever show it.
        let confirm = NSAlert()
        confirm.messageText = L10n.t("lid.install.confirm.title", "Set up closed-lid mode?")
        confirm.informativeText = L10n.t("lid.install.confirm.body",
            "macOS sleeps when you shut the lid, which kills whatever your agents are doing. "
            + "To prevent that, CodeCat needs to run one command as root, and asks for your "
            + "administrator password once to install two things:\n\n"
            + "• a sudoers rule at /etc/sudoers.d/codecat, allowing only 'pmset -a disablesleep 0' "
            + "and 'pmset -a disablesleep 1' for your user\n"
            + "• a background service that clears the flag if CodeCat ever stops while it is set\n\n"
            + "Both are removed by scripts/uninstall-lid-mode.sh.")
        confirm.addButton(withTitle: L10n.t("lid.install.confirm.button", "Show me the password prompt"))
        confirm.addButton(withTitle: L10n.t("button.cancel", "Cancel"))
        guard runInFront(confirm) == .alertFirstButtonReturn else { return }
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
                title: L10n.t("lid.setup.needed.title", "Nothing was installed"),
                message: L10n.t("lid.setup.needed.body",
                    "Closed-lid mode is still off. Turn it on whenever you're ready to enter "
                    + "the password."))
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
        runInFront(alert)
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
    /// during a view body: one `kill(pid, 0)` per visible row, and the running-app
    /// scan below only for a row whose recorded pid is already dead — a rare row, and
    /// one that would otherwise be drawn as unreachable.
    func route(for session: Session) -> JumpRoute {
        if isDemo { return demoRoute(for: session) }
        return SessionRouter.route(for: session, isHostRunning: SessionRouter.isProcessRunning,
                                   livePID: Self.runningPID(ofBundleID:))
    }

    /// Demo sessions have no host, and a card with no route is drawn dimmed — so
    /// every capture of the list would show dimmed cards. Finder stands in as the
    /// host: bringing it forward is harmless if a capture run clicks a card.
    private func demoRoute(for session: Session) -> JumpRoute {
        guard !demoUnroutable.contains(session.id),
              let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first,
              let url = finder.bundleURL
        else { return .unavailable(reason: .noHostRecorded) }
        return .application(pid: finder.processIdentifier, bundlePath: url.path)
    }

    /// The pid of a running instance of `bundleID`, or nil. Several instances are
    /// possible in principle; any of them can open a deep link, so the first will do.
    private static func runningPID(ofBundleID bundleID: String) -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first?.processIdentifier
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
            // makes such a card clickable in the first place (see
            // `SessionCardView`), so this branch is unreachable for it
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
        let alert = NSAlert()
        alert.messageText = message.title
        alert.informativeText = message.body
        runInFront(alert)
    }

    /// Re-reads the pet folders. Cheap, so it runs whenever the Cat pane appears;
    /// the registry is only republished when something actually changed, so an
    /// unchanged rescan does not redraw the pane.
    /// `@MainActor`: only caller is `CatPane`'s `onAppear`, and this now touches
    /// `SpriteSheetStore.shared` directly (see `forgetImported()` below), which is
    /// itself `@MainActor`.
    @MainActor
    func rescanPets() {
        // Unconditional, before the registry comparison below: a pet's sheet can
        // be re-hatched or edited in place without its id or manifest changing at
        // all, in which case `fresh == registry` and the early return below would
        // otherwise skip this entirely — leaving a stale sheet cached, or a sheet
        // that failed to load once (read mid-write) stuck in `failed` forever.
        SpriteSheetStore.shared.forgetImported()
        let fresh = Self.scanPets(reporting: &reportedPetProblems, log: log)
        if fresh != registry {
            registry = fresh
            // A pet the picker had selected can vanish from this very scan (folder
            // deleted, or edited into something `PetLibrary` now rejects). Without
            // this, `skinID` would keep pointing at an id the fresh registry no
            // longer has — `skin` already falls back to the default via
            // `registry.skin(withID:)`, but the picker's selection border compares
            // `skin.id == skinID` directly, so it would show no tile selected at
            // all while the mascot quietly rendered the default. See the `init`
            // comment: `skinID` and `skin.id` must never disagree.
            if registry.skin(withID: skinID).id != skinID {
                skinID = MascotSkins.default.id
            }
        }
    }

    private static func scanPets(reporting reported: inout Set<URL>, log: DiagnosticLog) -> SkinRegistry {
        let result = PetLibrary.discover(roots: PetLibrary.defaultRoots(),
                                         sheetSize: SpriteSheetStore.imageSize(at:))
        for report in result.skipped where reported.insert(report.folder).inserted {
            log.write("pet skipped: \(report.folder.lastPathComponent) — \(report.reason)")
        }
        return SkinRegistry(imported: result.skins)
    }

    /// Reports a skin whose sheets could not be read, and switches back to the
    /// default skin. Told with an alert rather than a line in the Cat pane
    /// because the pane may well be closed — this project's rule is that there are
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

/// "Show CodeCat as" (spec §8): the two display modes, or neither. "Menu bar only" is
/// `showMascot` off — the key every earlier build already wrote — so no setting moves.
enum ShowMode: Hashable, CaseIterable, Identifiable {
    case island, floating, menuBarOnly
    var id: Self { self }

    var title: String {
        switch self {
        case .island: return MascotDisplayMode.island.title
        case .floating: return MascotDisplayMode.floating.title
        case .menuBarOnly: return L10n.t("display.mode.menubar", "Menu bar only")
        }
    }
}

extension AppState {
    var showMode: ShowMode {
        get {
            guard showMascot else { return .menuBarOnly }
            return displayMode == .island ? .island : .floating
        }
        set {
            switch newValue {
            case .menuBarOnly:
                showMascot = false
            case .island:
                displayMode = .island
                showMascot = true
            case .floating:
                displayMode = .floating
                showMascot = true
            }
        }
    }
}
