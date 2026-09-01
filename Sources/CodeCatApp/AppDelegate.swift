import AppKit
import Combine
import CodeCatCore
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var statusItem: NSStatusItem!
    private var presenter: MascotPresenting?
    private var presentedMode: MascotDisplayMode?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        appState.start()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        appState.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateStatusIcon()
                self?.syncPresenter()
            }
            .store(in: &cancellables)
        updateStatusIcon()

        syncPresenter()
    }

    /// Держит на экране ровно один режим. Смена режима — это уничтожение старого
    /// контроллера и создание нового: у них разные окна, разная геометрия и разная
    /// модель ввода, и жить одновременно им незачем. Старый обязательно уводится с
    /// экрана до обнуления ссылки — иначе его окно осталось бы висеть.
    ///
    /// `.receive(on: DispatchQueue.main)` в подписке на `appState.objectWillChange`
    /// выше — не оптимизация, а условие корректности этого метода, по двум
    /// причинам:
    ///  1. `@Published` шлёт `objectWillChange` из `willSet`, то есть до того, как
    ///     новое значение записано. Без перехода на отдельный проход очереди
    ///     `syncPresenter()` читал бы `appState.displayMode` ещё старым,
    ///     `guard presentedMode != appState.displayMode` был бы всегда истинным
    ///     для «пока не записанного» значения, и режим не переключился бы вовсе.
    ///  2. Уничтожение старого контроллера здесь может уничтожить и панель меню,
    ///     из которой только что кликнули по `Picker` виду — переключить режим
    ///     можно прямо из меню острова. `.receive(on:)` откладывает это на
    ///     следующий проход `RunLoop`, когда стек обработки клика уже размотался,
    ///     а не рвёт из-под ног view, которая всё ещё обрабатывает событие.
    private func syncPresenter() {
        guard presentedMode != appState.displayMode else { return }
        presenter?.setVisible(false)
        presenter = nil
        presentedMode = appState.displayMode
        switch appState.displayMode {
        case .floating: presenter = OverlayController(appState: appState)
        case .island: presenter = IslandController(appState: appState)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState.shutdown()
    }

    private func updateStatusIcon() {
        let (symbol, description): (String, String)
        switch appState.store.aggregate {
        case .sleeping: (symbol, description) = ("moon.zzz", "спит")
        case .working(let n): (symbol, description) = ("cat.fill", "работает: \(n)")
        case .waiting(let n): (symbol, description) = ("exclamationmark.bubble.fill", "ждёт: \(n)")
        case .done: (symbol, description) = ("checkmark.circle.fill", "готово")
        case .problem: (symbol, description) = ("exclamationmark.triangle.fill", "проблема")
        }
        statusItem.button?.image = NSImage(
            systemSymbolName: symbol, accessibilityDescription: description)
        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        for session in appState.store.ordered {
            let status: String
            switch session.status {
            case .idle: status = "открыта"
            case .working: status = "работает"
            case .waitingForYou: status = "ждёт тебя"
            case .done: status = "закончил"
            case .crashed: status = "оборвалась"
            }
            let item = NSMenuItem(
                title: "\(session.projectName): \(status) — \(session.activityDescription)",
                action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        if !appState.store.ordered.isEmpty { menu.addItem(.separator()) }

        for mode in MascotDisplayMode.allCases {
            let item = NSMenuItem(title: "Вид: \(mode.title)",
                                  action: #selector(selectDisplayMode(_:)), keyEquivalent: "")
            item.state = (appState.displayMode == mode) ? .on : .off
            item.representedObject = mode.rawValue
            menu.addItem(item)
        }
        menu.addItem(.separator())

        menu.addItem(toggle("Не давать маку спать", appState.keepAwakeEnabled,
                            #selector(toggleKeepAwake)))
        menu.addItem(toggle("Режим закрытой крышки", appState.lidModeEnabled,
                            #selector(toggleLidMode)))
        menu.addItem(toggle("Звуки", appState.soundsEnabled, #selector(toggleSounds)))
        menu.addItem(toggle("Показывать котика", appState.showMascot, #selector(toggleMascot)))
        menu.addItem(.separator())
        if appState.hooksInstalled {
            menu.addItem(NSMenuItem(title: "Убрать хуки Claude Code…",
                                    action: #selector(removeHooks), keyEquivalent: ""))
        } else {
            menu.addItem(NSMenuItem(title: "Установить хуки Claude Code…",
                                    action: #selector(installHooks), keyEquivalent: ""))
        }
        let loginItem = NSMenuItem(title: "Запускать при логине",
                                   action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(.separator())
        // Версия видна прямо в меню, потому что иначе по установленному бандлу не
        // понять, что именно стоит: до 0.2.0 CFBundleVersion был «1» во всех сборках,
        // и две разные сборки на руках было нечем различить.
        let versionItem = NSMenuItem(title: "CodeCat \(Self.versionString)",
                                     action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        menu.addItem(NSMenuItem(title: "Выйти", action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items where item.action != nil { item.target = self }
        return menu
    }

    private func toggle(_ title: String, _ on: Bool, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.state = on ? .on : .off
        return item
    }

    @objc private func toggleKeepAwake() { appState.keepAwakeEnabled.toggle() }
    @objc private func toggleSounds() { appState.soundsEnabled.toggle() }
    @objc private func toggleMascot() { appState.showMascot.toggle() }

    @objc private func toggleLidMode() {
        appState.requestLidModeChange(to: !appState.lidModeEnabled)
    }

    /// Переключение вида живёт и здесь, а не только в панели: если остров окажется
    /// негде показать (встроенный экран отключён), маскота не будет видно вовсе, и
    /// вернуться к плавающему коту надо откуда-то ещё.
    @objc private func selectDisplayMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        appState.displayMode = MascotDisplayMode.mode(withID: raw)
    }

    @objc private func installHooks() { appState.installHooksIfNeeded() }

    @objc private func removeHooks() { appState.removeHooks() }

    /// «0.2.0 (136)». Build — число коммитов, проставляется в Info.plist при сборке
    /// бандла (см. Makefile). Запасные «?» на случай запуска не из бандла — при
    /// `swift run` Info.plist рядом нет, и падать из-за этого приложение не должно.
    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    @objc private func toggleLoginItem() {
        // работает только из собранного .app-бандла; при swift run молча игнорируем ошибку
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
        } else {
            try? SMAppService.mainApp.register()
        }
        statusItem.menu = buildMenu()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
