import AppKit
import SwiftUI
import Combine
import CodeCatCore

/// A borderless, non-activating floating panel used for both the cat mascot and its
/// details popup. `.nonactivatingPanel` lets it accept mouse/keyboard input without
/// ever bringing CodeCat to the front, so the user's current app never loses focus.
///
/// `allowsKey` is per-instance rather than hardcoded because the cat and the details
/// panel need different answers: the cat must NEVER take key status (it can be tapped
/// at any time without disturbing whatever the user is doing), while the details panel
/// needs to become key so its `Toggle`/`Button` controls actually receive clicks and
/// keyboard interaction — an AppKit panel that can never become key routinely fails to
/// deliver events to standard controls hosted inside it. Because the panel keeps
/// `.nonactivatingPanel`, becoming key still does not activate the app or steal focus
/// from whatever application was frontmost (this is the same mechanism `NSColorPanel`/
/// `NSFontPanel` rely on).
class OverlayPanel: NSPanel {
    private let allowsKey: Bool

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect, allowsKey: Bool) {
        self.allowsKey = allowsKey
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        // Dragging is implemented by hand in `CatHostingView` (see below), so the
        // window itself never needs to move the frame on a plain background click.
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
    }
}

/// Owns the cat panel and the details panel, and is the sole place that knows how
/// they relate to each other (position, visibility, click-to-open).
final class OverlayController: NSObject, NSWindowDelegate, MascotPresenting {
    /// `[x, y, canvas]`. The canvas the position was saved for is stored with it so
    /// changing the panel size migrates old positions instead of shifting the cat.
    private static let positionKey = "mascotPosition.v2"
    /// The bare `[x, y]` pair written by builds before the panel grew.
    private static let legacyPositionKey = "mascotPosition"
    private static let catSize = NSSize(width: MascotLayout.canvasSize,
                                        height: MascotLayout.canvasSize)

    private let appState: AppState
    private var catPanel: OverlayPanel!
    private var detailsPanel: OverlayPanel?
    private var cancellables: Set<AnyCancellable> = []

    init(appState: AppState) {
        self.appState = appState
        super.init()

        let origin = Self.validated(Self.savedOrigin()) ?? Self.defaultOrigin()
        let panel = OverlayPanel(contentRect: NSRect(origin: origin, size: Self.catSize), allowsKey: false)
        panel.delegate = self

        let hosting = CatHostingView(rootView: CatClickContent(appState: appState))
        hosting.onTap = { [weak self] in self?.toggleDetails() }
        panel.contentView = hosting
        catPanel = panel

        NotificationCenter.default.addObserver(
            self, selector: #selector(detailsDidResignKey(_:)),
            name: NSWindow.didResignKeyNotification, object: nil)

        appState.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.handleStateChange() }
            .store(in: &cancellables)

        setVisible(shouldShowMascot)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        // Симметрично `IslandController.deinit`: сегодня контроллер уничтожается
        // только после того, как вызывающий сам сделал `setVisible(false)`, так
        // что панели тут уже не на экране и это защита на будущее, а не действующий
        // путь. Но она должна стоять на обоих контроллерах уничтожения — иначе
        // читалось бы так, будто один из двух случаев опаснее другого.
        detailsPanel?.orderOut(nil)
        catPanel?.orderOut(nil)
    }

    /// Учитывает обе причины спрятать кота: тумблер «Показывать котика» и
    /// «Прятать котика, когда сессий нет». Вторую плавающий режим раньше не читал
    /// вовсе — тумблер стоял включённым, а кот оставался на экране, и настройка
    /// работала только в острове.
    private var shouldShowMascot: Bool {
        appState.showMascot && !appState.mascotShouldHideNow
    }

    /// Shows or hides the whole overlay (cat + details). Hiding the cat also hides
    /// the details panel so it is never left orphaned on screen once the mascot
    /// itself is gone.
    func setVisible(_ visible: Bool) {
        if visible {
            catPanel.orderFrontRegardless()
        } else {
            catPanel.orderOut(nil)
            hideDetails()
        }
    }

    private func handleStateChange() {
        setVisible(shouldShowMascot)
        // Keep the open details panel's session list, away log, and size in sync
        // with live state instead of only refreshing when it is next opened.
        if let panel = detailsPanel, panel.isVisible {
            resizeDetailsToFitContent()
            position(panel, relativeTo: catPanel)
        }
    }

    // MARK: - NSWindowDelegate (persist cat position)

    func windowDidMove(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel, panel === catPanel else { return }
        UserDefaults.standard.set(MascotLayout.storedValue(for: panel.frame.origin),
                                  forKey: Self.positionKey)
    }

    // MARK: - Details panel dismissal

    /// A non-activating panel that becomes key can still resign key (e.g. the user
    /// clicks on another app's window, or the desktop). Treat that as "click away
    /// to dismiss", the standard behavior for a popover-style panel.
    @objc private func detailsDidResignKey(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel, panel === detailsPanel else { return }
        hideDetails()
    }

    /// Orders the details panel out AND releases it, rather than just hiding it for
    /// reuse. The panel hosts up to eight simultaneous skin previews, each running
    /// its own `TimelineView(.periodic)` loop and `phaseAnimator` animation — capped
    /// at 4 fps precisely because the spec's battery budget assumes that view tree
    /// only exists while the panel is open. Keeping the `OverlayPanel` instance
    /// around between openings (as `toggleDetails()` used to do via `detailsPanel ??
    /// makeDetailsPanel()`) keeps its `NSHostingView<DetailsPanelView>` — and every
    /// preview inside it — alive and animating for the rest of the app's run, which
    /// defeats that budget. Dropping the reference here lets ARC deallocate the
    /// panel and its content, so `toggleDetails()` builds a genuinely fresh one next
    /// time. Do not change this back to a bare `orderOut(nil)` for reuse.
    private func hideDetails() {
        detailsPanel?.orderOut(nil)
        detailsPanel = nil
    }

    /// See `MascotPresenting.openMenuForCapture()`. Idempotent: called on an
    /// already-open panel it must not toggle it shut, which is why it does not
    /// simply forward to `toggleDetails()`.
    func openMenuForCapture() {
        guard detailsPanel?.isVisible != true else { return }
        toggleDetails()
    }

    private func toggleDetails() {
        if let panel = detailsPanel, panel.isVisible {
            hideDetails()
            return
        }
        // `hideDetails()` always clears `detailsPanel`, so by the time control
        // reaches here (the "not currently visible" branch) there is never a stale
        // instance to reuse — every open builds a fresh panel.
        let panel = makeDetailsPanel()
        detailsPanel = panel
        resizeDetailsToFitContent()
        position(panel, relativeTo: catPanel)
        panel.makeKeyAndOrderFront(nil)
    }

    private func makeDetailsPanel() -> OverlayPanel {
        let panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 290, height: 200), allowsKey: true)
        panel.contentView = NSHostingView(rootView: DetailsPanelView(
            appState: appState,
            onJump: { [weak self] in self?.hideDetails() }))
        return panel
    }

    /// The details panel's content is a variable-length list (sessions + away log
    /// entries), so a fixed contentRect either clips a long list or leaves dead
    /// space for a short one. Resize the panel to the SwiftUI content's own ideal
    /// size instead of guessing a constant.
    private func resizeDetailsToFitContent() {
        guard let panel = detailsPanel,
              let hosting = panel.contentView as? NSHostingView<DetailsPanelView> else { return }
        let fitting = hosting.fittingSize
        guard fitting.width > 0, fitting.height > 0 else { return }
        panel.setContentSize(fitting)
    }

    private func position(_ panel: NSPanel, relativeTo catPanel: NSPanel) {
        // The cat panel is larger than the cat: `MascotLayout.margin` of it is
        // transparent slack that keeps animations from being clipped. Lay the
        // details panel out against the drawing, not against that invisible edge,
        // so the gap between them is the gap the user actually sees.
        let catFrame = catPanel.frame.insetBy(dx: MascotLayout.margin, dy: MascotLayout.margin)
        let screen = NSScreen.screens.first { $0.frame.intersects(catFrame) } ?? NSScreen.main
        var origin = NSPoint(x: catFrame.minX - panel.frame.width - 12, y: catFrame.minY)

        if let vf = screen?.visibleFrame {
            // Prefer opening to the left of the cat; if that runs off the left edge
            // of the screen, open to the right instead.
            if origin.x < vf.minX {
                origin.x = catFrame.maxX + 12
            }
            origin.x = max(vf.minX, min(origin.x, vf.maxX - panel.frame.width))
            origin.y = max(vf.minY, min(origin.y, vf.maxY - panel.frame.height))
        }
        panel.setFrameOrigin(origin)
    }

    // MARK: - Position persistence

    private static func savedOrigin() -> NSPoint? {
        let defaults = UserDefaults.standard
        return MascotLayout.storedOrigin(
            current: defaults.array(forKey: positionKey) as? [Double],
            legacy: defaults.array(forKey: legacyPositionKey) as? [Double])
    }

    /// Guards against a saved position from a display that is no longer connected:
    /// if the remembered rect doesn't intersect any currently attached screen, fall
    /// back to the default corner instead of stranding the cat off-screen.
    private static func validated(_ origin: NSPoint?) -> NSPoint? {
        guard let origin else { return nil }
        let onScreen = MascotLayout.isOnScreen(origin: origin,
                                               screens: NSScreen.screens.map(\.visibleFrame))
        return onScreen ? origin : nil
    }

    private static func defaultOrigin() -> NSPoint {
        guard let screen = NSScreen.main else { return NSPoint(x: 100, y: 100) }
        return MascotLayout.defaultOrigin(visibleFrame: screen.visibleFrame, inset: 24)
    }
}

/// Pure rendering of `CatView` bound to live `AppState` — no gestures attached here.
/// Click and drag are both handled by `CatHostingView` below, at the AppKit level,
/// so they can be told apart (see its doc comment).
private struct CatClickContent: View {
    @ObservedObject var appState: AppState

    var body: some View {
        MascotView(skin: appState.skin,
                   status: appState.store.aggregate,
                   sessionCount: appState.store.badgeCount,
                   since: appState.statusSince,
                   onLoadFailure: { [appState] skin in appState.reportSkinLoadFailure(skin) })
            .contentShape(Rectangle())
    }
}

/// Hosts `CatClickContent` and implements click-vs-drag itself instead of combining
/// SwiftUI's `.onTapGesture` with `NSWindow.isMovableByWindowBackground`.
///
/// Those two don't compose the way the task brief's sample code assumed: SwiftUI's
/// tap gesture on AppKit is implemented by having the hosting view handle
/// `mouseDown`/`mouseUp` itself, which means the event never reaches
/// `NSWindow`'s "move by background" fallback (that fallback only fires when the
/// clicked view does *not* handle the mouse event). The practical effect of the
/// brief's approach would have been a cat that opens the details panel but can
/// never be dragged. Tracking mouseDown/mouseDragged/mouseUp directly, and treating
/// anything past a small movement threshold as a drag rather than a tap, gives both
/// behaviors reliably in the same view.
private final class CatHostingView: NSHostingView<CatClickContent> {
    var onTap: (() -> Void)?

    private var dragStartScreenPoint: NSPoint = .zero
    private var dragStartWindowOrigin: NSPoint = .zero
    private var didDrag = false
    private let dragThreshold: CGFloat = 3

    /// Without this, the very first click after launch (or after the cat panel's
    /// window last lost key-like focus) is swallowed by AppKit to "activate" the
    /// view's window instead of being delivered here — which would make the cat
    /// feel unresponsive on the first tap. The panel can never become key or
    /// activate the app regardless, so there's no downside to always accepting it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        didDrag = false
        dragStartScreenPoint = NSEvent.mouseLocation
        dragStartWindowOrigin = window?.frame.origin ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let current = NSEvent.mouseLocation
        let dx = current.x - dragStartScreenPoint.x
        let dy = current.y - dragStartScreenPoint.y
        if !didDrag && hypot(dx, dy) > dragThreshold {
            didDrag = true
        }
        if didDrag {
            window.setFrameOrigin(NSPoint(x: dragStartWindowOrigin.x + dx,
                                          y: dragStartWindowOrigin.y + dy))
        }
    }

    override func mouseUp(with event: NSEvent) {
        if !didDrag { onTap?() }
        didDrag = false
    }
}
