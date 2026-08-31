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
    let jumpExecutor: JumpExecuting

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

    /// Id of the selected skin. Persisted so the choice survives a restart; read
    /// back through `MascotSkins.skin(withID:)`, which falls back to
    /// `MascotSkins.default` for anything it does not recognise.
    @Published var skinID: String {
        didSet { UserDefaults.standard.set(skinID, forKey: "mascotSkin") }
    }

    /// Whether the "Об ассетах" credits disclosure in `SkinPickerView` is expanded.
    /// Lives here rather than as local `@State` on that view so toggling it
    /// publishes through `objectWillChange` like every other piece of visible
    /// state: `OverlayController.handleStateChange()` resizes the details panel to
    /// fit its SwiftUI content on that notification, and the credits list — the one
    /// attribution that is a licence obligation (mxmaze, CC BY 4.0) — must never
    /// open clipped inside a panel whose AppKit content rect didn't grow with it.
    @Published var creditsExpanded = false

    var skin: MascotSkin { MascotSkins.skin(withID: skinID) }

    /// Skins whose failure alert has already been shown. Only the *alert* is
    /// once-per-launch: the view that renders the mascot is rebuilt constantly, and
    /// an alert on every rebuild would be unusable. The fallback to the drawn cat in
    /// `reportSkinLoadFailure` is unconditional and runs every time, regardless of
    /// this set.
    private var reportedSkinFailures: Set<String> = []

    private var lidHelperInstallInFlight = false

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            "keepAwake": true, "lidMode": false, "sounds": false, "showMascot": true,
            "mascotSkin": MascotSkins.default.id,
        ])
        keepAwakeEnabled = defaults.bool(forKey: "keepAwake")
        lidModeEnabled = defaults.bool(forKey: "lidMode")
        soundsEnabled = defaults.bool(forKey: "sounds")
        showMascot = defaults.bool(forKey: "showMascot")
        skinID = defaults.string(forKey: "mascotSkin") ?? MascotSkins.default.id

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
        hooksInstalled = HooksInstaller.isInstalled(
            in: try? Data(contentsOf: CodeCatPaths.claudeSettings),
            hookCommand: hookBinaryPath())

        let server = HookSocketServer(path: CodeCatPaths.socketURL) { [weak self] event in
            guard let self else { return }
            self.store.apply(hook: event, now: Date())
            self.refresh()
        }
        do {
            try server.start()
        } catch {
            let message = "Не удалось запустить socket server на \(CodeCatPaths.socketURL.path): \(error)"
            FileHandle.standardError.write(message.data(using: .utf8) ?? Data())
            FileHandle.standardError.write("\n".data(using: .utf8) ?? Data())
        }
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

    func refresh() {
        let agg = store.aggregate
        // Power policy must read `store.anyWorking` (per-session), never `aggregate`
        // (a display-priority value where waiting outranks working) — otherwise one
        // session waiting on the user would wrongly cancel sleep-prevention for other
        // sessions that are still actively working.
        powerManager.update(anyWorking: store.anyWorking, now: Date())
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
            alert.messageText = "Не удалось установить хуки"
            alert.informativeText = "Не удалось прочитать файл настроек \(CodeCatPaths.claudeSettings.path). Проверьте права доступа и попробуйте снова."
            alert.runModal()
            return
        }

        guard let updated = try? HooksInstaller.install(
            into: existing, hookCommand: hookBinaryPath()) else {
            let alert = NSAlert()
            alert.messageText = "Не удалось установить хуки"
            alert.informativeText = "Не удалось обновить файл настроек \(CodeCatPaths.claudeSettings.path). Проверьте, что файл корректен."
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
            alert.messageText = "Не удалось установить хуки"
            alert.informativeText = "Не удалось записать в \(CodeCatPaths.claudeSettings.path): \(error.localizedDescription)"
            alert.runModal()
        }
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
                title: "Скрипт установки не найден",
                message: "Запусти вручную: sudo bash scripts/install-lid-mode.sh")
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
                    title: "Не удалось включить режим закрытой крышки",
                    message: "Установка завершилась, но правило всё ещё не найдено. Попробуй ещё раз или установи вручную: sudo bash scripts/install-lid-mode.sh")
            }
        case .cancelled:
            presentLidAlert(
                title: "Нужна разовая установка",
                message: "Режиму закрытой крышки требуется один раз разрешение администратора. Его можно включить позже — просто попробуй ещё раз, когда будешь готов ввести пароль.")
        case .failed(let detail):
            presentLidAlert(
                title: "Установка не удалась",
                message: "Скрипт установки завершился с ошибкой (\(detail)). Попробуй установить вручную: sudo bash scripts/install-lid-mode.sh")
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
            return (-1, "Не удалось запустить osascript: \(error.localizedDescription)")
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
            exeDir.appendingPathComponent("../Resources/\(name)"),  // внутри .app
            exeDir.appendingPathComponent("../../../scripts/\(name)"), // swift run из корня
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func shutdown() {
        lidController.resetOnExit()
        socketServer?.stop()
        watcher?.stop()
        timer?.invalidate()
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
        alert.messageText = "Не удалось загрузить облик «\(skin.name)»"
        alert.informativeText = "Файлы набора не читаются. Вернул облик по умолчанию."
        alert.window.level = .modalPanel
        alert.window.orderFrontRegardless()
        alert.runModal()
    }
}
