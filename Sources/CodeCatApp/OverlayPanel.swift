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
final class OverlayController: NSObject, NSWindowDelegate {
    private static let positionKey = "mascotPosition"
    private static let catSize = NSSize(width: 96, height: 96)

    private let appState: AppState
    private var catPanel: OverlayPanel!
    private var detailsPanel: OverlayPanel?
    private var cancellables: Set<AnyCancellable> = []

    init(appState: AppState) {
        self.appState = appState
        super.init()

        let origin = Self.validated(Self.savedOrigin(), size: Self.catSize) ?? Self.defaultOrigin(size: Self.catSize)
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

        setVisible(appState.showMascot)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
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
        setVisible(appState.showMascot)
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
        let o = panel.frame.origin
        UserDefaults.standard.set([Double(o.x), Double(o.y)], forKey: Self.positionKey)
    }

    // MARK: - Details panel dismissal

    /// A non-activating panel that becomes key can still resign key (e.g. the user
    /// clicks on another app's window, or the desktop). Treat that as "click away
    /// to dismiss", the standard behavior for a popover-style panel.
    @objc private func detailsDidResignKey(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel, panel === detailsPanel else { return }
        panel.orderOut(nil)
    }

    private func hideDetails() {
        detailsPanel?.orderOut(nil)
    }

    private func toggleDetails() {
        if let panel = detailsPanel, panel.isVisible {
            hideDetails()
            return
        }
        let panel = detailsPanel ?? makeDetailsPanel()
        detailsPanel = panel
        resizeDetailsToFitContent()
        position(panel, relativeTo: catPanel)
        panel.makeKeyAndOrderFront(nil)
    }

    private func makeDetailsPanel() -> OverlayPanel {
        let panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 290, height: 200), allowsKey: true)
        panel.contentView = NSHostingView(rootView: DetailsPanelView(appState: appState))
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
        let catFrame = catPanel.frame
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
        guard let arr = UserDefaults.standard.array(forKey: positionKey) as? [Double],
              arr.count == 2 else { return nil }
        return NSPoint(x: arr[0], y: arr[1])
    }

    /// Guards against a saved position from a display that is no longer connected:
    /// if the remembered rect doesn't intersect any currently attached screen, fall
    /// back to the default corner instead of stranding the cat off-screen.
    private static func validated(_ origin: NSPoint?, size: NSSize) -> NSPoint? {
        guard let origin else { return nil }
        let rect = NSRect(origin: origin, size: size)
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(rect) }
        return onScreen ? origin : nil
    }

    private static func defaultOrigin(size: NSSize) -> NSPoint {
        guard let screen = NSScreen.main else { return NSPoint(x: 100, y: 100) }
        let f = screen.visibleFrame
        return NSPoint(x: f.maxX - size.width - 24, y: f.minY + 24)
    }
}

/// Pure rendering of `CatView` bound to live `AppState` — no gestures attached here.
/// Click and drag are both handled by `CatHostingView` below, at the AppKit level,
/// so they can be told apart (see its doc comment).
private struct CatClickContent: View {
    @ObservedObject var appState: AppState

    var body: some View {
        CatView(status: appState.store.aggregate, sessionCount: appState.store.ordered.count)
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
