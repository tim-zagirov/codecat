import AppKit
import SwiftUI
import Combine
import CodeCatCore

/// The island: a black shape around the physical notch of a built-in display.
///
/// It only works where a notch exists. An external monitor, a closed lid and a Mac
/// without a notch all mean `computeGeometry() == nil`, and then the controller shows
/// nothing: control stays in the status-bar icon, from which the floating cat can
/// be brought back.
///
/// What the island does — inhale, open, close, peek — is decided by `IslandFlow` in
/// CodeCatCore, which is pure and tested and keeps `IslandPresenter` and
/// `PeekScheduler` together, so the island and the floating cat peek by one protocol.
/// This class feeds it the pointer, the session list and the clock and carries out
/// what it decided: the window's size, where hover and clicks count, and the
/// `IslandModel` the view draws from.
final class IslandController: NSObject, MascotPresenting {

    /// The menu bar sits at level 24 and other apps' status icons at 25; open system
    /// menus are at 101 (measured with `CGWindowLevelForKey`). The island goes to 26:
    /// above the menu bar and the icons but below open menus, so those draw over it
    /// and no fight over clicks arises.
    static let islandLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)

    private let appState: AppState
    private let model = IslandModel()
    private let pointer = PointerTracker()
    private var panel: OverlayPanel?
    private var hosting: IslandHostingView?
    private var flow: IslandFlow
    private var geometry: Geometry?
    /// The last requested visibility; `screensChanged()` re-applies it.
    private var isVisible = false
    /// The window is sized for the open island from the moment it starts opening
    /// until the close spring has settled (§5.2); otherwise it is the inhaled island
    /// plus the shadow margins, so a cursor near the notch but outside the island
    /// never lands in a large invisible window.
    private var canvasIsOpen = false
    private var shrink: DispatchWorkItem?
    /// One timer, at the flow's next deadline (dwell, close delay, peek hold, the gap
    /// before a queued peek), re-armed after every event: `tick` handles one deadline
    /// per call (handover contract 4).
    private var deadlineTimer: Timer?
    /// What the flow was last told about the pointer. Changes are fed only while
    /// no mouse button is down, so a drag across the notch never opens the island and
    /// a chip dragged out of it does not close it mid-drag (contract 5); a change seen
    /// with a button down waits for the button to come up.
    private var toldInside = false
    private var mouseUpMonitors: [Any] = []
    /// The open body's height as the view laid it out.
    private var expandedHeight: CGFloat = 0
    /// `--demo-inhale`: the dwell never completes, for a capture of the inhaled island.
    private var holdsInhale = false
    private var cancellables: Set<AnyCancellable> = []

    struct Geometry: Equatable {
        let visibleFrame: CGRect
        let notch: CGRect
        let island: CGRect
        let spriteSize: CGSize
    }

    init(appState: AppState) {
        self.appState = appState
        flow = IslandFlow(hoverDelay: appState.hoverDelay, settings: appState.peekSettings,
                          sessions: Array(appState.store.sessions.values), now: Date())
        super.init()
        model.onExpandedHeight = { [weak self] in self?.expandedHeightChanged($0) }
        model.onJump = { [weak self] in self?.jumped() }
        model.onSettings = { [weak self] in self?.openSettings() }
        model.onConnect = { [weak self] in self?.connect() }
        model.onShow = { [weak self] in self?.showList() }

        appState.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.handleStateChange() }
            .store(in: &cancellables)
        // Straight from the store's `$sessions` value, never through
        // `objectWillChange`: `@Published` sends that before the new value is stored,
        // and a peek is a diff between consecutive snapshots (Part 1 handover,
        // contract 1).
        appState.store.$sessions
            .sink { [weak self] sessions in self?.sessionsChanged(Array(sessions.values)) }
            .store(in: &cancellables)
        // The built-in display can be disconnected and reconnected — the notch
        // appears and disappears with it, and so does the room for the island.
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowBecameKey(_:)),
            name: NSWindow.didBecomeKeyNotification, object: nil)

        setVisible(appState.showMascot)
        if appState.isDemo, CommandLine.arguments.contains("--demo-inhale") { holdInhaleForCapture() }
    }

    deinit {
        // The panel has to be taken off screen explicitly: the controller dies when
        // the display mode changes, and a window left visible would outlive it.
        NotificationCenter.default.removeObserver(self)
        deadlineTimer?.invalidate()
        mouseUpMonitors.forEach(NSEvent.removeMonitor)
        panel?.orderOut(nil)
    }

    // MARK: - Visibility

    func setVisible(_ visible: Bool) {
        isVisible = visible
        // `mascotShouldHideNow` is the "hide when nothing is running" setting.
        guard visible, !appState.mascotShouldHideNow, let geometry = computeGeometry() else {
            closeImmediately()
            panel?.orderOut(nil)
            return
        }
        self.geometry = geometry
        if !holdsInhale { flow.hoverDelay = appState.hoverDelay }
        flow.settings = appState.peekSettings
        let metrics = IslandMetrics(
            notchWidth: geometry.notch.width,
            wingWidth: IslandLayout.wingWidth,
            stripHeight: geometry.island.height,
            bandHeight: geometry.notch.height,
            spriteSize: geometry.spriteSize,
            expandedMaxHeight: IslandLayout.expandedMaxHeight(visibleHeight: geometry.visibleFrame.height))
        if model.metrics != metrics { model.metrics = metrics }
        if panel == nil { makePanel() }
        applyFrame()
        panel?.orderFrontRegardless()
    }

    private func handleStateChange() {
        setVisible(appState.showMascot)
    }

    /// See `MascotPresenting.openMenuForCapture()`.
    func openMenuForCapture() {
        flow.open(now: Date())
        presenterChanged()
    }

    private func sessionsChanged(_ sessions: [Session]) {
        flow.sessionsChanged(sessions, now: Date())
        presenterChanged()
    }

    /// Show on a merged or away peek: the list, now, without a dwell (spec §6.2).
    private func showList() {
        flow.open(now: Date())
        presenterChanged()
    }

    // MARK: - Pointer

    /// Fed by the tracking area on every move, also while the window ignores the
    /// mouse: an `.activeAlways` tracking area keeps reporting `mouseMoved` to an
    /// ignoring window (logged; captured as a cursor entering through the margin
    /// below the wing, then inhaling on the wing).
    private func pointerMoved(_ point: CGPoint?) {
        // A `nil` (the tracking area's exit) is checked against where the cursor
        // really is. `giveUpKeyboard()` orders the window out and back in, and the
        // tracking area answers with an exit and a fresh entry under a cursor that
        // never moved; taken at its word, that entry inhaled the island Escape had
        // just closed, and 0.3 s later it was open again (logged, captured).
        reconcile(inside: point.map(isInsideSilhouette) ?? cursorIsOnSilhouette())
        updateClickTarget()
    }

    private func isInsideSilhouette(_ point: CGPoint) -> Bool {
        hosting?.silhouette?.contains(point) ?? false
    }

    private func reconcile(inside: Bool) {
        guard inside != toldInside else { return }
        guard NSEvent.pressedMouseButtons == 0 else {
            waitForMouseUp()
            return
        }
        toldInside = inside
        if inside {
            flow.pointerEntered(now: Date())
        } else {
            flow.pointerLeft(now: Date())
        }
        presenterChanged()
    }

    /// A button came down while the pointer crossed the silhouette. The change is
    /// fed once the button is up — which can happen anywhere on screen, so the
    /// monitors are global as well as local.
    private func waitForMouseUp() {
        guard mouseUpMonitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseUp, .rightMouseUp, .otherMouseUp]
        let released: () -> Void = { [weak self] in
            DispatchQueue.main.async { self?.mouseReleased() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { _ in released() }) {
            mouseUpMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            released()
            return event
        }) {
            mouseUpMonitors.append(local)
        }
    }

    private func mouseReleased() {
        mouseUpMonitors.forEach(NSEvent.removeMonitor)
        mouseUpMonitors = []
        resyncPointer()
        updateClickTarget()
    }

    /// Where the cursor really is, fed as if it had moved there — after the window
    /// changed size under a still cursor, or a button came up. Without it the
    /// flow could go on believing the pointer is inside a shape that shrank away
    /// from it, and the island would never inhale again.
    private func resyncPointer() {
        reconcile(inside: cursorIsOnSilhouette())
    }

    /// Asked of the cursor's real position rather than the last reported one: the
    /// window may have changed size under it since.
    private func cursorIsOnSilhouette() -> Bool {
        guard let panel, let hosting, panel.isVisible else { return false }
        let local = hosting.convert(panel.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        return hosting.bounds.contains(local) && isInsideSilhouette(hosting.canvasPoint(local))
    }

    /// Whether the window takes clicks at all (spec §4.3, S15): only while the island
    /// is open and the cursor is on its shape. Everywhere else — the closed island's
    /// wings over the menu bar, the margin beside the open shape, the room a peek's
    /// window leaves below it — the window ignores the mouse, so a click there reaches
    /// what lies under it. A `nil` from `hitTest` was not enough: it only means no
    /// view takes the click, after the window server has already handed it to this
    /// window (logged: `sendEvent` saw the mouse-down on the closed wing and made the
    /// panel key). With this, a click on the menu bar beside the open island's fillet
    /// never reached the panel (logged). The tracking area keeps reporting the
    /// pointer to an ignoring window, so hover works throughout.
    ///
    /// Left alone while a button is down: the window that took the mouse-down keeps
    /// the drag to its mouse-up, and `mouseReleased` settles it afterwards.
    private func updateClickTarget() {
        guard let panel, NSEvent.pressedMouseButtons == 0 else { return }
        let ignores = !(flow.presentation.isOpen && cursorIsOnSilhouette())
        if panel.ignoresMouseEvents != ignores { panel.ignoresMouseEvents = ignores }
    }

    // MARK: - Presenter

    /// Carries out whatever the flow decided. Opening sizes the window before the
    /// view hears of it, so the spring starts in a window that already fits; closing
    /// keeps the window open until the close spring has settled.
    private func presenterChanged() {
        let old = model.presentation
        let new = flow.presentation
        if new.isOpen, !old.isOpen { beginOpening() }
        if !new.isOpen, old.isOpen { beginClosing() }
        if model.presentation != new { model.presentation = new }
        if model.peekHold != flow.peekHold { model.peekHold = flow.peekHold }
        updateSilhouette()
        // Tim, 2026-09-30: a peek that grows under a resting cursor counts as hover.
        // The tracking area reports nothing for a cursor that did not move, so the
        // cursor is read once the peek's outline exists (Part 2 handover, contract 7).
        if case .peek = new, !old.isOpen { resyncPointer() }
        armTimer()
    }

    private func beginOpening() {
        shrink?.cancel()
        shrink = nil
        canvasIsOpen = true
        applyFrame()
    }

    private func beginClosing() {
        giveUpKeyboard()
        shrink?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.shrink = nil
            self.canvasIsOpen = false
            self.applyFrame()
            self.resyncPointer()
        }
        shrink = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.closeSettle, execute: work)
    }

    /// A click inside made the panel key (`OverlayPanel.sendEvent`) so a card works in
    /// one click. Once the island closes, keystrokes must go back to what the user was
    /// typing in; ordering the panel out and straight back in returns key status to
    /// the active app's window.
    private func giveUpKeyboard() {
        guard let panel, panel.isKeyWindow else { return }
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }

    private func armTimer() {
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        guard let deadline = flow.nextDeadline else { return }
        let timer = Timer(fire: max(deadline, Date()), interval: 0, repeats: false) { [weak self] _ in
            self?.deadlineReached()
        }
        RunLoop.main.add(timer, forMode: .common)
        deadlineTimer = timer
    }

    private func deadlineReached() {
        // A button pressed during the dwell — a drag starting at the island's edge, a
        // click on the menu title under a wing — must not end in an open island. It
        // counts as the pointer leaving; the mouse-up feeds it back in.
        if flow.presentation == .inhaled, NSEvent.pressedMouseButtons != 0 {
            toldInside = false
            flow.pointerLeft(now: Date())
            waitForMouseUp()
            presenterChanged()
            return
        }
        flow.tick(now: Date())
        presenterChanged()
    }

    private func jumped() {
        flow.jumped(now: Date())
        presenterChanged()
    }

    private func escape() {
        flow.escape(now: Date())
        presenterChanged()
    }

    private func openSettings() {
        escape()
        NotificationCenter.default.post(name: .codecatShowSettings, object: nil)
    }

    /// The dialogs behind Connect… are modal, and while one is up the tracking area
    /// reports nothing: the cursor that left the island for the dialog's buttons was
    /// never fed as leaving, and the island stayed open over the menu bar until the
    /// pointer next moved. Asking where the cursor is once the modal returns closes
    /// it then, or keeps it open if the cursor is back on it.
    private func connect() {
        appState.installHooksIfNeeded()
        resyncPointer()
        updateClickTarget()
    }

    private func holdInhaleForCapture() {
        holdsInhale = true
        flow.hoverDelay = 3600
        toldInside = true
        flow.pointerEntered(now: Date())
        presenterChanged()
    }

    /// The island is leaving the screen or its screen changed: no animation, no
    /// pointer left behind.
    private func closeImmediately() {
        giveUpKeyboard()
        if toldInside {
            flow.pointerLeft(now: Date())
            toldInside = false
        }
        flow.escape(now: Date())
        shrink?.cancel()
        shrink = nil
        canvasIsOpen = false
        if model.presentation != flow.presentation { model.presentation = flow.presentation }
        if model.peekHold != flow.peekHold { model.peekHold = flow.peekHold }
        armTimer()
    }

    // MARK: - Window

    private func applyFrame() {
        guard let panel, let geometry else { return }
        let largest = canvasIsOpen
            ? IslandLayout.openCanvasBody(maxHeight: model.metrics.expandedMaxHeight)
            : IslandLayout.body(for: .inhaled, compact: geometry.island.size, expandedHeight: 0)
        let frame = Self.onWholePoints(IslandLayout.canvasFrame(island: geometry.island, largest: largest),
                                       centreX: geometry.island.midX)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        updateSilhouette()
    }

    /// The canvas with its origin on a whole point, widened by up to a point so its
    /// centre stays on the notch's. The view centres the shape, the cat and the wing
    /// on the canvas, but AppKit puts a window's origin on a whole point: on a
    /// MacBook whose notch is centred at x 863.5 the open canvas asked for x 611.5, and
    /// the island and the cat stood half a point left of the compact ones — a jump
    /// each time the window grew and shrank (1 px in the captures).
    ///
    /// The height is rounded up for the same reason, from the top: the island is a
    /// rim's width (1.5 pt) taller than the notch, so the closed canvas is 77.5 pt
    /// tall, and an origin moved onto a whole point would pull the shape's top half
    /// a point off the screen's edge.
    private static func onWholePoints(_ frame: CGRect, centreX: CGFloat) -> CGRect {
        let minX = frame.minX.rounded(.down)
        let height = frame.height.rounded(.up)
        return CGRect(x: minX, y: frame.maxY - height, width: 2 * (centreX - minX), height: height)
    }

    /// Hover and clicks are judged against the shape the island is heading to, never
    /// against the window, and the closed island takes no clicks at all.
    private func updateSilhouette() {
        guard let panel, let hosting, let geometry else { return }
        let presentation = flow.presentation
        // Until the view has measured the list, the open outline is at least the
        // inhaled one, so the cursor that opened the island is still inside it.
        let openHeight = max(expandedHeight, geometry.island.height + IslandLayout.inhaleGrowth.height)
        let body = IslandLayout.body(for: presentation, compact: geometry.island.size, expandedHeight: openHeight)
        hosting.silhouette = IslandLayout.silhouettePath(canvasWidth: panel.frame.width, body: body)
        hosting.clickThrough = !presentation.isOpen
        updateClickTarget()
    }

    private func expandedHeightChanged(_ height: CGFloat) {
        expandedHeight = height
        updateSilhouette()
    }

    private func makePanel() {
        // `allowsKey`: the open island holds buttons, which need a window that can be
        // key. It becomes key only on a mouse-down inside it (`OverlayPanel.sendEvent`,
        // `becomesKeyOnlyOnClick`) — never at launch, never from hover.
        let panel = OverlayPanel(contentRect: .zero, allowsKey: true)
        panel.becomesKeyOnlyOnClick = true
        panel.ignoresMouseEvents = true
        panel.level = Self.islandLevel
        panel.acceptsMouseMovedEvents = true
        // `giveUpKeyboard()` orders the panel out and straight back in. A panel's
        // default `orderOut` fades it, and the whole island vanished for about 0.3 s
        // at the start of every close (captured: frames 2-5 of the close burst) before
        // `orderFrontRegardless` snapped it back.
        panel.animationBehavior = .none
        let hosting = IslandHostingView(rootView: IslandView(appState: appState, model: model, pointer: pointer))
        // The window's size is the controller's decision; without this the hosting
        // view would push its own idea of a fitting size onto it.
        hosting.sizingOptions = []
        hosting.pointer = pointer
        hosting.onPointer = { [weak self] in self?.pointerMoved($0) }
        hosting.onEscape = { [weak self] in self?.escape() }
        panel.contentView = hosting
        self.panel = panel
        self.hosting = hosting
    }

    /// Escape reaches `keyDown` only through the first responder, and a click that
    /// made the panel key leaves one of SwiftUI's own views there.
    @objc private func windowBecameKey(_ notification: Notification) {
        guard let panel, let hosting, (notification.object as? NSWindow) === panel else { return }
        panel.makeFirstResponder(hosting)
    }

    /// `didChangeScreenParametersNotification` is not documented to arrive on the main
    /// thread, and `computeGeometry()` — through `assumeIsolated` — kills the process
    /// if it is reached from another one. So the hop is explicit.
    @objc private func screensChanged() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.screensChanged() }
            return
        }
        closeImmediately()
        setVisible(isVisible)
    }

    /// The notched display and all the geometry derived from it. `nil` means the
    /// island has nowhere to live.
    private func computeGeometry() -> Geometry? {
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
        // The invariant: every path here arrives on the main thread. Three calls reach
        // `computeGeometry()` today, all through `setVisible(_:)`:
        //  - from `init` (via `setVisible(appState.showMascot)`);
        //  - from `handleStateChange()` (via `setVisible(appState.showMascot)`), which
        //    `appState.objectWillChange` drives through a Combine sink with
        //    `.receive(on: DispatchQueue.main)`;
        //  - from `screensChanged()` (via `setVisible(isVisible)`), which hops to the
        //    main thread explicitly before calling — see its comment.
        // If a path from another thread ever appears, `assumeIsolated` will not warn
        // about it — it will kill the process. Keep that in mind when editing.
        // There is a fourth caller of `setVisible`: `setVisible(false)` from
        // `AppDelegate.syncPresenter()` (itself running on the main thread). It never
        // reaches `computeGeometry()` — the `guard visible` in `setVisible` cuts it off
        // earlier. If `setVisible(false)` ever starts computing geometry, that path
        // needs checking separately.
        let spriteSize = MainActor.assumeIsolated {
            SpriteSheetStore.shared.load(appState.skin)?
                .drawingSize(targetHeight: SpriteScale.islandTargetHeight,
                             maxWidth: SpriteScale.islandMaxWidth)
        } ?? CGSize(width: 24, height: 24)
        return Geometry(visibleFrame: screen.visibleFrame,
                        notch: notch,
                        island: IslandLayout.islandFrame(notch: notch),
                        spriteSize: spriteSize)
    }
}
