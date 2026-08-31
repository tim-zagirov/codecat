import AppKit
import Combine
import CodeCatCore
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var statusItem: NSStatusItem!
    private var overlay: OverlayController?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        appState.start()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        appState.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateStatusIcon()
            }
            .store(in: &cancellables)
        updateStatusIcon()

        overlay = OverlayController(appState: appState)
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

        menu.addItem(toggle("Не давать маку спать", appState.keepAwakeEnabled,
                            #selector(toggleKeepAwake)))
        menu.addItem(toggle("Режим закрытой крышки", appState.lidModeEnabled,
                            #selector(toggleLidMode)))
        menu.addItem(toggle("Звуки", appState.soundsEnabled, #selector(toggleSounds)))
        menu.addItem(toggle("Показывать котика", appState.showMascot, #selector(toggleMascot)))
        menu.addItem(.separator())
        if !appState.hooksInstalled {
            menu.addItem(NSMenuItem(title: "Установить хуки Claude Code…",
                                    action: #selector(installHooks), keyEquivalent: ""))
        }
        let loginItem = NSMenuItem(title: "Запускать при логине",
                                   action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(loginItem)
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

    @objc private func installHooks() { appState.installHooksIfNeeded() }

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
