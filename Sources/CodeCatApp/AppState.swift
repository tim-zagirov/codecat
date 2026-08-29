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
    let store = SessionStore()
    let awayLog = AwayLog()
    let powerManager: PowerManager
    let lidController: LidSleepController

    private var socketServer: HookSocketServer?
    private var watcher: TranscriptWatcher?
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var lastAggregate: AggregateStatus = .sleeping

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

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            "keepAwake": true, "lidMode": false, "sounds": false, "showMascot": true,
        ])
        keepAwakeEnabled = defaults.bool(forKey: "keepAwake")
        lidModeEnabled = defaults.bool(forKey: "lidMode")
        soundsEnabled = defaults.bool(forKey: "sounds")
        showMascot = defaults.bool(forKey: "showMascot")

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
        hooksInstalled = HooksInstaller.isInstalled(
            in: try? Data(contentsOf: CodeCatPaths.claudeSettings),
            hookCommand: hookBinaryPath())

        let server = HookSocketServer(path: CodeCatPaths.socketURL) { [weak self] event in
            guard let self else { return }
            self.store.apply(hook: event, now: Date())
            self.refresh()
        }
        try? server.start()
        socketServer = server

        let watcher = TranscriptWatcher(root: CodeCatPaths.projectsRoot) { [weak self] activity in
            guard let self else { return }
            self.store.apply(activity: activity)
            self.refresh()
        }
        watcher.start()
        self.watcher = watcher

        // периодическое обслуживание
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = Date()
            self.store.reconcile(claudeProcessCount: ProcessScanner.claudeProcessCount(), now: now)
            self.store.expireFinished(now: now)
            if !self.hooksInstalled {
                self.store.applyIdleHeuristic(now: now)
            }
            self.powerManager.tick(now: now)
            self.refresh()
        }

        observeScreenLock()
        store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func refresh() {
        let agg = store.aggregate
        let working: Bool
        if case .working = agg { working = true } else { working = false }
        powerManager.update(anyWorking: working, now: Date())
        lidController.update(shouldPreventSleep: powerManager.isHolding)
        notifyTransition(to: agg)
        lastAggregate = agg
        objectWillChange.send()
    }

    private func notifyTransition(to agg: AggregateStatus) {
        guard agg != lastAggregate else { return }
        switch agg {
        case .waiting:
            awayLog.record("агент ждёт тебя", at: Date())
            if soundsEnabled { NSSound(named: "Purr")?.play() }
        case .done:
            awayLog.record("агент закончил работу", at: Date())
            if soundsEnabled { NSSound(named: "Glass")?.play() }
        case .problem:
            awayLog.record("сессия оборвалась", at: Date())
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
        let existing = try? Data(contentsOf: CodeCatPaths.claudeSettings)
        guard let updated = try? HooksInstaller.install(
            into: existing, hookCommand: hookBinaryPath()) else { return }
        try? FileManager.default.createDirectory(
            at: CodeCatPaths.claudeSettings.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? updated.write(to: CodeCatPaths.claudeSettings)
        hooksInstalled = true
    }

    func shutdown() {
        lidController.resetOnExit()
        socketServer?.stop()
        watcher?.stop()
        timer?.invalidate()
    }
}
