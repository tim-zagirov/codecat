import AppKit
import SwiftUI
import Combine
import CodeCatCore

/// The island: a black slab around the physical notch of a built-in display.
///
/// It only works where a notch exists. An external monitor, a closed lid and a Mac
/// without a notch all mean `geometry() == nil`, and then the controller shows
/// nothing: control stays in the status-bar icon, from which the floating cat can
/// be brought back.
final class IslandController: NSObject, MascotPresenting {

    /// The menu bar sits at level 24 and other apps' status icons at 25; open system
    /// menus are at 101 (measured with `CGWindowLevelForKey`). The island goes to 26:
    /// above the menu bar and the icons but below open menus, so those draw over it
    /// and no fight over clicks arises.
    static let islandLevel = NSWindow.Level(
        rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)

    private let appState: AppState
    private var islandPanel: OverlayPanel?
    private var menuLevel: IslandMenuLevel?
    /// The menu collapses on a spring while its content is still mounted;
    /// `pendingTeardown` takes the content down afterwards.
    private var isCollapsing = false
    /// Which menu level is collapsing right now: the content has to stay on screen
    /// while the silhouette travels back, or there would be nothing to collapse.
    private var collapsingLevel: IslandMenuLevel?
    private var pendingClose: DispatchWorkItem?
    /// Tearing the menu window down after the closing animation arrives. Kept apart
    /// from `pendingClose` (which decides *whether to close* the short menu when the
    /// cursor leaves): the menu can be reopened in the middle of closing, and then the
    /// teardown must be cancelled without touching the hover logic.
    private var pendingTeardown: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []
    /// The last requested visibility of the island. `screensChanged()` reads it: it
    /// calls `setVisible(isVisible)` to redisplay the island after a display
    /// configuration change, without asking `AppState.showMascot` again (which by then
    /// may not have changed at all).
    private var isVisible = false

    /// Everything worth knowing about the geometry right now. Recomputed on every
    /// state change: the skin may have changed, a display may have been disconnected.
    struct Geometry {
        let screen: NSScreen
        let notch: CGRect
        let island: CGRect
        let spriteSize: CGSize
    }

    init(appState: AppState) {
        self.appState = appState
        super.init()

        appState.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.handleStateChange() }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            self, selector: #selector(menuDidResignKey(_:)),
            name: NSWindow.didResignKeyNotification, object: nil)

        // The built-in display can be disconnected and reconnected — the notch appears
        // and disappears with it, and so does the room for the island.
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        setVisible(appState.showMascot)
    }

    deinit {
        // The panel has to be taken off screen explicitly: the controller dies when the
        // display mode changes, and a window left visible would outlive it.
        NotificationCenter.default.removeObserver(self)
        islandPanel?.orderOut(nil)
    }

    func setVisible(_ visible: Bool) {
        isVisible = visible
        // `mascotShouldHideNow` is the "hide when nothing is running" setting. The menu
        // goes with it: there would be nothing left to anchor it to.
        guard visible, !appState.mascotShouldHideNow, let geometry = geometry() else {
            dropMenu()
            islandPanel?.orderOut(nil)
            return
        }
        let panel = islandPanel ?? makePanel()
        islandPanel = panel
        let hosting = self.hosting(of: panel) ?? {
            let hosting = IslandHostingView(rootView: content(for: geometry))
            hosting.onEnter = { [weak self] in self?.pointerEnteredRegion() }
            hosting.onExit = { [weak self] in self?.pointerLeftRegion() }
            hosting.onClick = { [weak self] in self?.islandClicked() }
            panel.contentView = hosting
            return hosting
        }()
        hosting.rootView = content(for: geometry)
        hosting.islandStripHeight = geometry.island.height
        applyFrame(panel: panel, hosting: hosting, geometry: geometry)
        panel.orderFrontRegardless()
    }

    private func handleStateChange() {
        setVisible(appState.showMascot)
    }

    // MARK: - Hover and click

    /// The cursor is inside the window. One window now holds both the island and the
    /// menu, so there is one question: this used to mean asking about two windows and
    /// making sure moving the mouse from the island onto the menu did not count as leaving.
    private func pointerEnteredRegion() {
        pendingClose?.cancel()
        pendingClose = nil
        if menuLevel == nil { showMenu(.short) }
    }

    private func pointerLeftRegion() {
        // The full menu closes only on a click outside: it holds toggles and the skin
        // picker, and it must not vanish while the user is moving the mouse towards the
        // switch they want.
        guard menuLevel == .short else { return }
        pendingClose?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Ask where the cursor actually is rather than trusting the order of
            // events: by now the window may already have grown under it.
            guard !self.pointerIsInsideRegion() else { return }
            self.hideMenu()
        }
        pendingClose = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// `NSEvent.mouseLocation` is in the same screen coordinates as `NSWindow.frame`.
    private func pointerIsInsideRegion() -> Bool {
        guard let panel = islandPanel, panel.isVisible else { return false }
        return panel.frame.contains(NSEvent.mouseLocation)
    }

    private func islandClicked() {
        switch menuLevel {
        case .full: hideMenu()
        case .short: expandMenu()
        case nil: showMenu(.full)
        }
    }

    /// Going from short to full is a change of content in the same window, with no
    /// recreation: the session list has no business blinking and rebuilding itself.
    /// The height catches up on the same spring inside `IslandView`.
    private func expandMenu() {
        guard let panel = islandPanel, let hosting = hosting(of: panel),
              let geometry = geometry() else { return }
        menuLevel = .full
        hosting.rootView = content(for: geometry)
        applyFrame(panel: panel, hosting: hosting, geometry: geometry)
        // The full menu has to become key, or the toggles, the mode picker and the
        // hooks button inside it never receive clicks.
        panel.makeKeyAndOrderFront(nil)
    }

    /// See `MascotPresenting.openMenuForCapture()`.
    func openMenuForCapture() {
        showMenu(.full)
    }

    private func showMenu(_ level: IslandMenuLevel) {
        guard let panel = islandPanel, let hosting = hosting(of: panel),
              let geometry = geometry() else { return }
        pendingTeardown?.cancel()
        pendingTeardown = nil
        isCollapsing = false
        collapsingLevel = nil
        menuLevel = level
        hosting.rootView = content(for: geometry)
        applyFrame(panel: panel, hosting: hosting, geometry: geometry)
        if level == .full {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    /// - Parameter animated: close on a spring, mirroring the reveal. `false` for the
    ///   paths where waiting is not possible: the island is leaving the screen
    ///   entirely, the display mode is changing, another menu is opening in its place.
    private func hideMenu(animated: Bool = true) {
        pendingClose?.cancel()
        pendingClose = nil
        pendingTeardown?.cancel()
        pendingTeardown = nil

        guard animated, menuLevel != nil, let panel = islandPanel,
              let hosting = hosting(of: panel), let geometry = geometry() else {
            dropMenu()
            return
        }

        // From this moment the menu no longer counts as open: a click on the island
        // while it closes must reopen it, not close it a second time. The content
        // itself stays mounted — the silhouette is what collapses it.
        collapsingLevel = menuLevel
        menuLevel = nil
        isCollapsing = true
        hosting.rootView = content(for: geometry)

        let teardown = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingTeardown = nil
            self.dropMenu()
        }
        pendingTeardown = teardown
        DispatchQueue.main.asyncAfter(deadline: .now() + IslandView.revealDuration,
                                      execute: teardown)
    }

    /// Takes the menu's content down and shrinks the window back to the island strip.
    /// The window stays the same one: this is a single shape, not two.
    private func dropMenu() {
        pendingTeardown?.cancel()
        pendingTeardown = nil
        menuLevel = nil
        isCollapsing = false
        collapsingLevel = nil
        guard let panel = islandPanel, let hosting = hosting(of: panel),
              let geometry = geometry() else { return }
        hosting.rootView = content(for: geometry)
        applyFrame(panel: panel, hosting: hosting, geometry: geometry)
    }

    private func hosting(of panel: OverlayPanel) -> IslandHostingView? {
        panel.contentView as? IslandHostingView
    }

    /// Sets the window frame and the hit-test outline in ONE action.
    ///
    /// Together rather than separately, deliberately: an outline that lags behind cuts
    /// clicks on painted area, which is worse than having none. The first version of
    /// this fix updated the outline in only two of four places — caught by grep rather
    /// than by tests, because in practice it would only have shown up in those rare
    /// transitions. A single entry point makes that mistake impossible.
    ///
    /// The outline is computed with exactly the arguments `IslandView` builds its own
    /// mask from: `IslandShape(bottomRadius: IslandLayout.cornerRadius)` across the
    /// window's full width.
    private func applyFrame(panel: OverlayPanel, hosting: IslandHostingView,
                            geometry: Geometry) {
        let frame = windowFrame(for: geometry, hosting: hosting)
        panel.setFrame(frame, display: true)
        hosting.silhouette = IslandLayout.silhouettePath(
            in: CGRect(x: 0, y: 0, width: frame.width, height: frame.height),
            bottomRadius: IslandLayout.cornerRadius)
    }

    /// The window frame for the current content. The height is asked of the layout
    /// itself (`fittingSize`) rather than computed: the menu is assembled from the
    /// session list and the settings, and its height depends on how many sessions exist.
    private func windowFrame(for geometry: Geometry, hosting: IslandHostingView) -> NSRect {
        let fitting = hosting.fittingSize.height
        let total = fitting > 0 ? fitting : geometry.island.height
        return IslandLayout.windowFrame(island: geometry.island,
                                        totalHeight: total,
                                        screenFrame: geometry.screen.frame)
    }

    @objc private func menuDidResignKey(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel, panel === islandPanel,
              menuLevel == .full else { return }
        hideMenu()
    }

    /// The display configuration changed — a notch may have appeared or disappeared
    /// with it. `didChangeScreenParametersNotification` is documented nowhere as
    /// guaranteed to arrive on the main thread (Apple confirms only that the
    /// notification is posted, not on which thread), and `geometry()` — through
    /// `assumeIsolated` — does not forgive that mistake: it does not warn about a
    /// violation, it kills the process. So the hop to the main thread here is explicit
    /// rather than merely assumed.
    @objc private func screensChanged() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.screensChanged() }
            return
        }
        hideMenu()
        setVisible(isVisible)
    }

    private func makePanel() -> OverlayPanel {
        // `allowsKey: true`: one window holds both the island and the menu, and the
        // full menu contains toggles and buttons — without the right to become key they
        // receive no clicks. The window is only made key by a click
        // (`makeKeyAndOrderFront`); hover shows the menu with `orderFrontRegardless`
        // and does not touch focus.
        let panel = OverlayPanel(contentRect: .zero, allowsKey: true)
        panel.level = Self.islandLevel
        panel.acceptsMouseMovedEvents = true
        return panel
    }

    private func content(for geometry: Geometry) -> IslandView {
        IslandView(appState: appState,
                   notchWidth: geometry.notch.width,
                   wingWidth: IslandLayout.wingWidth,
                   spriteSize: geometry.spriteSize,
                   height: geometry.island.height,
                   menuLevel: menuLevel ?? (isCollapsing ? collapsingLevel : nil),
                   isCollapsing: isCollapsing,
                   onJump: { [weak self] in self?.hideMenu() })
    }

    /// The notched display and all the geometry derived from it. `nil` means the
    /// island has nowhere to live.
    private func geometry() -> Geometry? {
        // Search directly for what is needed — the first screen a notch can be built
        // for — rather than for `safeAreaInsets.top > 0` (`IslandLayout.hasNotch`).
        // The order of `NSScreen.screens` is documented nowhere as "built-in first",
        // and the behaviour of `safeAreaInsets.top` on external displays is untested.
        // If the filter were on the inset rather than the notch itself, a display with
        // no notch but a non-zero inset could sneak in first and stop the search before
        // the built-in screen was ever considered — and the island would silently fail
        // to appear. `hasNotch` is not redundant for that: it is a documented predicate
        // in its own right with its own test, just not the only filter here.
        guard let found = NSScreen.screens.lazy.compactMap({ screen in
            IslandLayout.notchRect(auxLeft: screen.auxiliaryTopLeftArea,
                                   auxRight: screen.auxiliaryTopRightArea).map { (screen, $0) }
        }).first
        else { return nil }
        let (screen, notch) = found

        // `SpriteSheetStore` is `@MainActor`-isolated (see its doc comment: every
        // caller already runs on the main thread). `IslandController` itself is not
        // marked `@MainActor` — that would cascade `@MainActor` onto `AppDelegate` and
        // from there onto the global `delegate` in `main.swift`, well beyond the scope
        // of this work. But in fact everything reaches here from the main thread:
        // AppKit panels, and a Combine sink subscribed through
        // `.receive(on: DispatchQueue.main)`. `assumeIsolated` simply states that fact
        // rather than changing the architecture.
        //
        // The invariant: every path here arrives on the main thread. Six calls reach
        // `geometry()` today:
        //  - from `init` (via `setVisible(appState.showMascot)`);
        //  - from `handleStateChange()` twice — via `setVisible(...)` and directly,
        //    when relaying an already-open menu under new geometry;
        //  - from `pointerEnteredRegion()` (via `showMenu(.short)`) — called from
        //    `mouseEntered` on the island's host view and the menu's;
        //  - from `islandClicked()` (via `showMenu(.full)`) — called from `mouseUp` on
        //    the island's host view;
        //  - from `screensChanged()` (via `setVisible(isVisible)`), which hops to the
        //    main thread explicitly before calling — see its comment.
        // `handleStateChange()` gets here through a Combine sink with
        // `.receive(on: DispatchQueue.main)`, and `pointerEnteredRegion()` and
        // `islandClicked()` through overrides of `NSResponder.mouseEntered` / `mouseUp`,
        // which AppKit always delivers on the main thread. If a path from another
        // thread ever appears, `assumeIsolated` will not warn about it — it will kill
        // the process. Keep that in mind when editing.
        // There is a seventh path: `setVisible(false)` from `AppDelegate.syncPresenter()`
        // (itself running on the main thread). Today it never reaches `geometry()` —
        // the `guard visible` in `setVisible` cuts it off earlier. If `setVisible(false)`
        // ever starts computing geometry, that path needs checking separately.
        let spriteSize = MainActor.assumeIsolated {
            SpriteSheetStore.shared.load(appState.skin)?
                .drawingSize(targetHeight: SpriteScale.islandTargetHeight,
                             maxWidth: SpriteScale.islandMaxWidth)
        } ?? CGSize(width: 24, height: 24)
        return Geometry(screen: screen,
                        notch: notch,
                        island: IslandLayout.islandFrame(notch: notch),
                        spriteSize: spriteSize)
    }
}
