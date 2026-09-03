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
        // `--demo` drives the mascot through every state on a loop, for screenshots
        // and for the landing-page recording (scripts/capture-screenshots.sh). It
        // replaces `start()` rather than adding to it — see `startDemo`.
        if CommandLine.arguments.contains("--demo") {
            appState.startDemo(pinnedPhase: Self.pinnedDemoPhase())
            // `--demo-open-menu` is what lets the capture script photograph the
            // session list and the skin grid: with the app hidden from every
            // screen-control tool, there is no other way to open them.
            if CommandLine.arguments.contains("--demo-open-menu") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.presenter?.openMenuForCapture()
                }
            }
        } else {
            appState.start()
        }

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

    /// Keeps exactly one mode on screen. Changing mode means destroying the old
    /// controller and creating a new one: they have different windows, different
    /// geometry and different input models, and no reason to coexist. The old one is
    /// always taken off screen before its reference is cleared — otherwise its window
    /// would be left hanging.
    ///
    /// The `.receive(on: DispatchQueue.main)` in the subscription to
    /// `appState.objectWillChange` above is not an optimisation but a precondition for
    /// this method's correctness, for two reasons:
    ///  1. `@Published` sends `objectWillChange` from `willSet`, i.e. before the new
    ///     value is stored. Without hopping to a separate pass of the queue,
    ///     `syncPresenter()` would read `appState.displayMode` still holding the old
    ///     value, `guard presentedMode != appState.displayMode` would always be true
    ///     for the not-yet-written value, and the mode would never switch at all.
    ///  2. Destroying the old controller here can also destroy the menu panel the
    ///     `Picker` was just clicked in — the mode can be switched from inside the
    ///     island menu. `.receive(on:)` defers that to the next pass of the `RunLoop`,
    ///     once the click's handling stack has unwound, instead of pulling the ground
    ///     out from under a view that is still processing the event.
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

    /// `--demo-phase=idle|working|waiting|done`, for a capture that must not race
    /// the four-second loop. An unrecognised name means "loop", not "crash": this
    /// flag exists for a script, and a typo in it should cost a retake, not a
    /// launch failure.
    private static func pinnedDemoPhase() -> DemoFeed.Phase? {
        guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--demo-phase=") })
        else { return nil }
        switch argument.dropFirst("--demo-phase=".count) {
        case "idle": return .idle
        case "working": return .working
        case "waiting": return .waiting
        case "done": return .done
        default: return nil
        }
    }

    private func updateStatusIcon() {
        let (symbol, description): (String, String)
        switch appState.store.aggregate {
        case .sleeping:
            (symbol, description) = ("moon.zzz", L10n.t("menubar.asleep", "asleep"))
        case .working(let n):
            (symbol, description) = ("cat.fill", L10n.f("menubar.working", "working: %d", n))
        case .waiting(let n):
            (symbol, description) = ("exclamationmark.bubble.fill",
                                     L10n.f("menubar.waiting", "waiting: %d", n))
        case .done:
            (symbol, description) = ("checkmark.circle.fill", L10n.t("menubar.done", "done"))
        case .problem:
            (symbol, description) = ("exclamationmark.triangle.fill",
                                     L10n.t("menubar.problem", "problem"))
        }
        statusItem.button?.image = NSImage(
            systemSymbolName: symbol, accessibilityDescription: description)
        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        for session in appState.store.ordered {
            let item = NSMenuItem(
                title: "\(session.projectName): \(session.status.title) — \(session.activityDescription)",
                action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        if !appState.store.ordered.isEmpty { menu.addItem(.separator()) }

        for mode in MascotDisplayMode.allCases {
            let item = NSMenuItem(title: L10n.f("menu.view", "View: %@", mode.title),
                                  action: #selector(selectDisplayMode(_:)), keyEquivalent: "")
            item.state = (appState.displayMode == mode) ? .on : .off
            item.representedObject = mode.rawValue
            menu.addItem(item)
        }
        menu.addItem(.separator())

        menu.addItem(toggle(L10n.t("setting.keep.awake", "Keep the Mac awake"),
                            appState.keepAwakeEnabled, #selector(toggleKeepAwake)))
        menu.addItem(toggle(L10n.t("setting.lid.mode", "Closed-lid mode"),
                            appState.lidModeEnabled, #selector(toggleLidMode)))
        menu.addItem(toggle(L10n.t("setting.sounds", "Sounds"),
                            appState.soundsEnabled, #selector(toggleSounds)))
        menu.addItem(toggle(L10n.t("setting.show.cat", "Show the cat"),
                            appState.showMascot, #selector(toggleMascot)))
        // A duplicate of the item in the settings panel, and mandatory here rather than
        // a convenience: turning "hide" on removes both the mascot and the menu living
        // inside it from the screen, leaving nowhere to turn it back off. The menu bar
        // is always there.
        menu.addItem(toggle(L10n.t("setting.hide.when.idle", "Hide the cat when nothing is running"),
                            appState.hidesWhenNoSessions, #selector(toggleHideWhenIdle)))
        menu.addItem(.separator())
        if appState.hooksInstalled {
            menu.addItem(NSMenuItem(title: L10n.t("menu.hooks.remove", "Remove Claude Code hooks…"),
                                    action: #selector(removeHooks), keyEquivalent: ""))
        } else {
            menu.addItem(NSMenuItem(title: L10n.t("menu.hooks.install", "Install Claude Code hooks…"),
                                    action: #selector(installHooks), keyEquivalent: ""))
        }
        let loginItem = NSMenuItem(title: L10n.t("menu.login.item", "Open at login"),
                                   action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(.separator())
        // The version is visible right in the menu, because otherwise there is no way
        // to tell what is installed: before 0.2.0 CFBundleVersion was "1" in every
        // build, and two different builds were indistinguishable.
        let versionItem = NSMenuItem(title: "CodeCat \(Self.versionString)",
                                     action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        menu.addItem(NSMenuItem(title: L10n.t("menu.quit", "Quit"),
                                action: #selector(quit), keyEquivalent: "q"))
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

    @objc private func toggleHideWhenIdle() { appState.hidesWhenNoSessions.toggle() }

    @objc private func toggleLidMode() {
        appState.requestLidModeChange(to: !appState.lidModeEnabled)
    }

    /// The mode switch lives here too, not only in the panel: if the island turns out
    /// to have nowhere to appear (the built-in display is disconnected), the mascot is
    /// not visible at all, and getting back to the floating cat has to be possible.
    @objc private func selectDisplayMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        appState.displayMode = MascotDisplayMode.mode(withID: raw)
    }

    @objc private func installHooks() { appState.installHooksIfNeeded() }

    @objc private func removeHooks() { appState.removeHooks() }

    /// "0.2.0 (136)". The build is the commit count, written into Info.plist when the
    /// bundle is assembled (see the Makefile). The "?" fallbacks are for running
    /// outside a bundle — with `swift run` there is no Info.plist beside the binary,
    /// and the app must not crash over that.
    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    @objc private func toggleLoginItem() {
        // works only from an assembled .app bundle; with swift run the error is ignored
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
        } else {
            try? SMAppService.mainApp.register()
        }
        statusItem.menu = buildMenu()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
