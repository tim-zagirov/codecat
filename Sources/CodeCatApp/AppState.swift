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
    /// Единственный способ узнать, что происходило внутри: приложение `LSUIElement`,
    /// у него нет ни окна, ни консоли, и инструменты управления экраном его не видят.
    /// До появления этого файла разбор приходилось вести внешним двойником на
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

    /// Когда маскот вошёл в то состояние, которое показывает сейчас. Движение из
    /// нескольких фаз («потянулся — улёгся — спит») без этой точки отсчёта не знает,
    /// отыграна ли уже одноразовая часть, а хранить счётчик в самом виде нельзя: он
    /// пересоздаётся при каждом открытии панели и смене облика.
    ///
    /// Считается по `AggregateStatusKey`, а не по `AggregateStatus`: число сессий на
    /// движение не влияет, и переход «работает 1» → «работает 2» не должен дёргать
    /// анимацию с начала.
    @Published private(set) var statusSince = Date()

    /// Id of the selected skin. Persisted so the choice survives a restart; read
    /// back through `MascotSkins.skin(withID:)`, which falls back to
    /// `MascotSkins.default` for anything it does not recognise.
    @Published var skinID: String {
        didSet { UserDefaults.standard.set(skinID, forKey: "mascotSkin") }
    }

    /// Как показывать маскота. Персистится, чтобы выбор пережил перезапуск;
    /// читается через `MascotDisplayMode.mode(withID:)`, который откатывает
    /// незнакомую строку к режиму по умолчанию.
    @Published var displayMode: MascotDisplayMode {
        didSet { UserDefaults.standard.set(displayMode.rawValue, forKey: "mascotDisplayMode") }
    }

    /// Прятать остров, когда сессий нет вовсе. По умолчанию выключено: остров
    /// стоит на одном месте, и на него всегда можно навести мышь.
    @Published var islandHidesWhenIdle: Bool {
        didSet { UserDefaults.standard.set(islandHidesWhenIdle, forKey: "islandHidesWhenIdle") }
    }

    /// Должен ли остров прямо сейчас быть скрыт по настройке «прятать, когда
    /// сессий нет».
    ///
    /// Условие — именно отсутствие сессий, а не «кот спит». Раньше здесь стоял
    /// `aggregate == .sleeping`, и это совпадало с подписью ровно до тех пор, пока
    /// всякая известная сессия считалась работающей. Теперь открытая, но
    /// простаивающая сессия даёт `.sleeping` — и остров исчезал с экрана, хотя
    /// сессии были и были видны в панели. Обещание подписи важнее: прячем, когда
    /// прятать действительно нечего.
    var islandShouldHideNow: Bool {
        guard islandHidesWhenIdle else { return false }
        return !store.hasSessions
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
        islandHidesWhenIdle = defaults.bool(forKey: "islandHidesWhenIdle")
        // Resolve through `MascotSkins.skin(withID:)` rather than trusting the raw
        // stored string: an id from an older build (e.g. the retired `"drawn"`) must
        // migrate to the default skin here, at read time, so `skinID` and `skin.id`
        // never disagree. Assigning the raw value directly would leave a stale id
        // sitting in `skinID` — rendering the default skin correctly, but with no
        // tile selected in `SkinPickerView` (it compares `skin.id == skinID`) until
        // the user happens to tap one, since `didSet` does not fire on `init`.
        skinID = MascotSkins.skin(withID: defaults.string(forKey: "mascotSkin") ?? MascotSkins.default.id).id

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
        // Ротация именно здесь, а не только в обслуживании: приложение может
        // проработать без перезапуска сутками, но и наоборот — запускаться часто и
        // жить недолго, и тогда 15-секундный тик до предела просто не доживёт.
        log.rotateIfNeeded()
        let info = Bundle.main.infoDictionary
        log.write("запуск — версия \(info?["CFBundleShortVersionString"] as? String ?? "?") "
            + "(\(info?["CFBundleVersion"] as? String ?? "?")), вид: \(displayMode.rawValue), "
            + "облик: \(skinID)")

        hooksInstalled = HooksInstaller.isInstalled(
            in: try? Data(contentsOf: CodeCatPaths.claudeSettings),
            hookCommand: hookBinaryPath())
        log.write("хуки установлены: \(hooksInstalled), бинарник: \(hookBinaryPath())")

        let server = HookSocketServer(path: CodeCatPaths.socketURL) { [weak self] event in
            guard let self else { return }
            // Строка на каждое ПРИНЯТОЕ событие. Вместе со строкой, которую пишет сам
            // хук перед отправкой, это единственный способ отличить «Claude Code не
            // позвал хук» от «позвал, но до приложения не дошло»: снаружи обе
            // неисправности выглядят одинаково — котик просто не шевелится.
            self.log.write("событие \(event.hookEventName) сессия=\(event.sessionId.prefix(8)) "
                + "cwd=\(event.cwd ?? "—") tty=\(event.tty ?? "—")")
            self.store.apply(hook: event, now: Date())
            self.refresh()
        }
        do {
            try server.start()
            log.write("сокет слушает: \(CodeCatPaths.socketURL.path)")
        } catch {
            // Раньше это уходило в FileHandle.standardError, то есть в никуда:
            // бандл запускают из Finder, и стандартного вывода у него нет.
            log.write("ОШИБКА: не удалось поднять сокет на \(CodeCatPaths.socketURL.path): \(error)")
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
            // Ротацию делает только приложение — см. DiagnosticLog: хук, переименовав
            // файл, увёл бы его из-под уже открытого здесь дескриптора.
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
        // Переход состояния — это то, что видно глазами как поза котика. Записанный
        // рядом с событиями хука, он отвечает на главный вопрос ручной проверки:
        // «кот показывает не то — событие не пришло или пришло, но состояние
        // посчиталось иначе?»
        log.write("состояние: \(lastAggregate) → \(agg), сессий: \(store.ordered.count)")
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

    /// Убирает хуки CodeCat из `~/.claude/settings.json`.
    ///
    /// Зеркало `installHooksIfNeeded()` и обязательное условие честной деинсталляции:
    /// без него утилита, стёртая из /Applications, оставляла бы в настройках Claude
    /// Code пять записей, зовущих несуществующий бинарник — на каждое событие каждой
    /// сессии. `HooksInstaller.remove` вычищает только записи с нашей командой,
    /// оставляя чужие хуки и все прочие ключи нетронутыми.
    ///
    /// Спрашивает подтверждение: это правка пользовательского файла настроек, а не
    /// нашего собственного состояния.
    func removeHooks() {
        let existing: Data?
        switch HooksInstaller.readSettings(at: CodeCatPaths.claudeSettings) {
        case .notFound:
            // Файла нет — убирать нечего, и это не ошибка. Но флаг сбрасываем:
            // раз настроек нет, то и наших хуков в них нет.
            hooksInstalled = false
            return
        case .data(let data):
            existing = data
        case .unreadable:
            // Ровно та же осторожность, что и при установке, и по той же причине:
            // `remove` трактует nil как пустой документ, и запись такого результата
            // затёрла бы реальные настройки пользователя целиком.
            presentHooksAlert(
                title: "Не удалось убрать хуки",
                message: "Не удалось прочитать файл настроек \(CodeCatPaths.claudeSettings.path). Проверьте права доступа и попробуйте снова.")
            return
        }

        let confirm = NSAlert()
        confirm.messageText = "Убрать хуки CodeCat?"
        confirm.informativeText = "Из \(CodeCatPaths.claudeSettings.path) будут удалены записи CodeCat для событий: \(HooksInstaller.events.joined(separator: ", ")). Чужие хуки и остальные настройки останутся как есть.\n\nБез хуков котик продолжит работать, но о состоянии сессий будет узнавать с задержкой — по транскриптам, а не по событиям."
        confirm.addButton(withTitle: "Убрать")
        confirm.addButton(withTitle: "Отмена")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        guard let updated = try? HooksInstaller.remove(
            from: existing, hookCommand: hookBinaryPath()) else {
            presentHooksAlert(
                title: "Не удалось убрать хуки",
                message: "Не удалось обновить файл настроек \(CodeCatPaths.claudeSettings.path). Проверьте, что файл корректен.")
            return
        }

        do {
            // .atomic по той же причине, что и при установке: оборванная запись не
            // имеет права оставить пользователя с обрезанным settings.json.
            try updated.write(to: CodeCatPaths.claudeSettings, options: .atomic)
            hooksInstalled = false
        } catch {
            presentHooksAlert(
                title: "Не удалось убрать хуки",
                message: "Не удалось записать в \(CodeCatPaths.claudeSettings.path): \(error.localizedDescription)")
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
        log.write("выход")
        lidController.resetOnExit()
        socketServer?.stop()
        watcher?.stop()
        timer?.invalidate()
        // Последним: всё, что выше, ещё может захотеть записаться.
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
        alert.messageText = "Не удалось загрузить облик «\(skin.name)»"
        // Must not claim which skin ended up on screen: if the whole `Skins`
        // directory is missing, the default skin's own sheets fail to load too, and
        // the user is looking at `CatView`'s drawn-cat fallback, not the default
        // skin. Naming only the skin that failed and saying "мы переключились" keeps
        // this true in both cases.
        alert.informativeText = "Файлы набора не читаются. Переключились на другой облик."
        alert.window.level = .modalPanel
        alert.window.orderFrontRegardless()
        alert.runModal()
    }
}
