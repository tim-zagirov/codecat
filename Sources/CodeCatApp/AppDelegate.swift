import AppKit
import Combine
import CodeCatCore

extension Notification.Name {
    /// "•••" on the island (and on the floating panel): opens the Settings window.
    static let codecatShowSettings = Notification.Name("CodeCatShowSettings")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var statusItem: NSStatusItem!
    private var presenter: MascotPresenting?
    private var presentedMode: MascotDisplayMode?
    private var cancellables: Set<AnyCancellable> = []
    private lazy var settings = SettingsWindowController(appState: appState)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()
        // `--demo` drives the mascot through every state on a loop, for screenshots
        // and for the landing-page recording (scripts/capture-screenshots.sh). It
        // replaces `start()` rather than adding to it — see `startDemo`.
        if CommandLine.arguments.contains("--demo") {
            let arguments = CommandLine.arguments
            appState.demoLidOn = arguments.contains("--demo-lid")
            let peek = arguments.first(where: { $0.hasPrefix("--demo-peek=") })
                .flatMap { DemoFeed.PeekDemo(rawValue: String($0.dropFirst("--demo-peek=".count))) }
            // A peek is a change, so it is played on a scene: the working phase unless
            // `--demo-phase=` names another.
            let pin = Self.demoPin() ?? (peek == nil ? nil : .phase(.working))
            appState.startDemo(pin: pin,
                               hooksInstalled: !arguments.contains("--demo-phase=firstrun"),
                               unroutable: arguments.contains("--demo-noroute") ? [DemoFeed.sessionIDs[1]] : [],
                               peek: peek)
            // `--demo-expanded` (and the older `--demo-open-menu`) open the island or
            // the floating panel for a capture: the app is hidden from every
            // screen-control tool, so there is no other way to open them.
            if arguments.contains("--demo-expanded") || arguments.contains("--demo-open-menu") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.presenter?.openMenuForCapture()
                }
            }
            if let name = arguments.first(where: { $0.hasPrefix("--demo-settings=") })?
                .dropFirst("--demo-settings=".count),
               let pane = SettingsPane.named(String(name)) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.settings.show(pane)
                    self?.settings.placeForCapture()
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
        NotificationCenter.default.addObserver(forName: .codecatShowSettings, object: nil, queue: .main) {
            [weak self] _ in
            self?.settings.show()
        }

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
        case .floating: presenter = FloatingController(appState: appState)
        case .island: presenter = IslandController(appState: appState)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState.shutdown()
    }

    /// `--demo-phase=idle|working|waiting|done|problem|one-working|one-waiting|`
    /// `one-done|many|showcase|empty|firstrun`, for a capture that must not race the
    /// four-second loop. `--demo-peek=waiting|crashed|done|merged|away` pins `working`
    /// when no phase is named, and plays its peek on it 1.5 s after launch; `away`
    /// plays its change behind a pretend screen lock (`AppState.demoAway()`). An
    /// unrecognised name means "loop", not "crash": this flag exists for a script,
    /// and a typo in it should cost a retake, not a launch failure.
    private static func demoPin() -> DemoFeed.Pin? {
        guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--demo-phase=") })
        else { return nil }
        switch argument.dropFirst("--demo-phase=".count) {
        case "idle": return .phase(.idle)
        case "working": return .phase(.working)
        case "waiting": return .phase(.waiting)
        case "done": return .phase(.done)
        case "problem": return .problem
        case "one-working": return .single(.working)
        case "one-waiting": return .single(.waiting)
        case "one-done": return .single(.done)
        case "many": return .many
        case "showcase": return .showcase
        case "empty", "firstrun": return .empty
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
        // The SF Symbol is only the fallback for a bundle missing `menubar.pdf`; the
        // mark itself says nothing aloud, so the state is spoken from the label.
        statusItem.button?.image = BrandMark.statusImage(for: appState.store.aggregate)
            ?? NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        statusItem.button?.setAccessibilityLabel(description)
        statusItem.menu = buildMenu()
    }

    /// An accessory app shows no menu bar, but its main menu still answers key
    /// equivalents while one of its windows is key — the only way ⌘, ⌘W and ⌘Q reach
    /// the Settings window (spec §8).
    private func installMainMenu() {
        let main = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: L10n.t("menubar.settings", "Settings…"),
                                   action: #selector(openSettings), keyEquivalent: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: L10n.t("menu.quit", "Quit"), action: #selector(quit), keyEquivalent: "q"))
        for item in appMenu.items where item.action != nil { item.target = self }
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)
        let windowMenu = NSMenu(title: L10n.t("menu.window", "Window"))
        windowMenu.addItem(NSMenuItem(title: L10n.t("menu.close", "Close"),
                                      action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        let windowItem = NSMenuItem()
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }

    @objc private func openSettings() { settings.show() }

    /// spec §8: "Show CodeCat as ▸, Settings… ⌘,, separator, version, Quit".
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let showItem = NSMenuItem(title: L10n.t("settings.show.as", "Show CodeCat as"), action: nil, keyEquivalent: "")
        let showMenu = NSMenu()
        // Items are enabled by hand (the island without a notch is not), which
        // automatic validation would override.
        showMenu.autoenablesItems = false
        for mode in ShowMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(selectShowMode(_:)), keyEquivalent: "")
            item.state = appState.showMode == mode ? .on : .off
            // Refused without a notch, like the Settings picker.
            item.isEnabled = mode != .island || NotchScreen.exists
            item.representedObject = mode
            item.target = self
            showMenu.addItem(item)
        }
        showItem.submenu = showMenu
        menu.addItem(showItem)
        menu.addItem(NSMenuItem(title: L10n.t("menubar.settings", "Settings…"),
                                action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        // The version is visible right in the menu, because otherwise there is no way
        // to tell what is installed: before 0.2.0 CFBundleVersion was "1" in every
        // build, and two different builds were indistinguishable.
        let versionItem = NSMenuItem(title: "CodeCat \(Self.versionString)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        menu.addItem(NSMenuItem(title: L10n.t("menu.quit", "Quit"), action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items where item.action != nil { item.target = self }
        return menu
    }

    @objc private func selectShowMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? ShowMode else { return }
        appState.showMode = mode
    }

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

    @objc private func quit() { NSApp.terminate(nil) }
}
