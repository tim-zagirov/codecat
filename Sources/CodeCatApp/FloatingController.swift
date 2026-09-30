import AppKit
import SwiftUI
import Combine
import CodeCatCore

/// The floating cat (spec §9): a cat on its capsule in a window the user drags, and
/// next to it one panel for the peek or the list. `IslandFlow` decides what shows,
/// the same driver as the island's; this class feeds it the pointer, the clock and
/// the sessions, and places the panel (`FloatingLayout`).
///
/// Unlike the island, the cat is a click target: a click opens the list at once
/// (`IslandFlow.open`), a click on an open list closes it; resting on the cat for the
/// hover delay opens it too.
final class FloatingController: NSObject, NSWindowDelegate, MascotPresenting {
    /// `[x, y, canvas]`. The canvas the position was saved for is stored with it so
    /// changing the window's size migrates old positions instead of shifting the cat.
    private static let positionKey = "mascotPosition.v2"
    /// The bare `[x, y]` pair written by builds before the panel grew.
    private static let legacyPositionKey = "mascotPosition"

    private let appState: AppState
    private let model = FloatingModel()
    private var flow: IslandFlow
    private var catPanel: OverlayPanel!
    private var openPanel: OverlayPanel?
    /// One timer, at the flow's next deadline, re-armed after every event (handover
    /// contract 4), as on the island.
    private var deadlineTimer: Timer?
    /// What the flow was last told about the pointer; fed only while no button is
    /// down, so a drag of the cat never opens or closes the list on the way.
    private var toldInside = false
    /// The list's natural height plus the panel's padding, as last measured; 0 until
    /// the list has been laid out once.
    private var listHeight: CGFloat = 0
    /// What the open panel shows on screen, for how its shape changes next; nil while
    /// no panel is visible (none, or the first list's panel still waiting,
    /// transparent, for its height).
    private var shownKind: OpenKind?
    private var shapeRevision = 0
    /// A peek that turned into a list above the cat (decision 3 meeting decision 9):
    /// the band from the peek's bottom up to the list, which counts as inside until
    /// the cursor leaves it. The cursor that rested on the peek is no longer on any
    /// shape once the list opens above the cat, and the list closed itself 150 ms
    /// after opening (recorded) — and a cursor moving up to it crosses empty space
    /// beside the cat.
    private var peekBridge: CGRect?
    /// Waits for the button held past the hover delay to come up (`deadlineReached`).
    private var mouseUpMonitors: [Any] = []
    private var cancellables: Set<AnyCancellable> = []
    private var pointerMonitor: Any?
    private var keyObserver: NSObjectProtocol?

    init(appState: AppState) {
        self.appState = appState
        flow = IslandFlow(hoverDelay: appState.hoverDelay, settings: appState.peekSettings,
                          sessions: Array(appState.store.sessions.values), now: Date())
        super.init()
        let anchor = Self.validated(Self.savedAnchor()) ?? Self.defaultAnchor()
        let panel = OverlayPanel(contentRect: NSRect(origin: FloatingLayout.catWindowOrigin(anchor: anchor),
                                                     size: FloatingLayout.catWindowSize), allowsKey: false)
        panel.delegate = self
        // The cat stands on the panel's shape: its window stays above the panel's.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        // The cursor reaches the cat through the window's transparent margin, so the
        // move onto the cat itself is a mouse-moved event, which a tracking area gets
        // only from a window that accepts them.
        panel.acceptsMouseMovedEvents = true
        let hosting = CatHostingView(rootView: FloatingCatView(appState: appState, model: model))
        hosting.onTap = { [weak self] in self?.catClicked() }
        hosting.onHover = { [weak self] _ in self?.pointerMoved() }
        hosting.onDragStart = { [weak self] in self?.dragStarted() }
        // Pointer changes are not fed while a button is down; the mouse-up reads the
        // cursor again, after the click or the drag has been handled.
        hosting.onMouseUp = { [weak self] in DispatchQueue.main.async { self?.pointerMoved() } }
        panel.contentView = hosting
        catPanel = panel

        model.onJump = { [weak self] in self?.jumped() }
        model.onShow = { [weak self] in self?.open() }
        // As on the island: the dialogs behind Connect… are modal and the tracking
        // areas report nothing meanwhile, so the cursor is read once they are gone.
        model.onConnect = { [weak self] in appState.installHooksIfNeeded(); self?.pointerMoved() }
        model.onListHeight = { [weak self] in self?.listMeasured($0) }

        appState.objectWillChange.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.handleStateChange() }
            .store(in: &cancellables)
        // Contract 1, as on the island: the value, synchronously.
        appState.store.$sessions
            .sink { [weak self] sessions in self?.sessionsChanged(Array(sessions.values)) }
            .store(in: &cancellables)
        // Spec §6.2: no peeks while the screen is locked, one summary after it.
        appState.$screenIsLocked.removeDuplicates()
            .sink { [weak self] locked in
                guard let self else { return }
                if locked { self.flow.lock(now: Date()) } else { self.flow.unlock(now: Date()) }
                self.presenterChanged()
            }
            .store(in: &cancellables)
        setVisible(shouldShowMascot)
    }

    deinit {
        // The controller dies when the display mode changes; a window left visible
        // would outlive it.
        deadlineTimer?.invalidate()
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        mouseUpMonitors.forEach(NSEvent.removeMonitor)
        openPanel?.orderOut(nil)
        catPanel?.orderOut(nil)
    }

    /// Accounts for both reasons to hide the cat: the "Show the cat" toggle and "Hide
    /// the cat when nothing is running".
    private var shouldShowMascot: Bool { appState.showMascot && !appState.mascotShouldHideNow }

    /// Hiding the cat closes the list with it, so it is never left orphaned on screen.
    func setVisible(_ visible: Bool) {
        if model.isOnScreen != visible { model.isOnScreen = visible }
        if visible {
            catPanel.orderFrontRegardless()
        } else {
            if toldInside {
                toldInside = false
                flow.pointerLeft(now: Date())
            }
            flow.escape(now: Date())
            presenterChanged()
            catPanel.orderOut(nil)
        }
    }

    /// See `MascotPresenting.openMenuForCapture()`. Idempotent: `IslandFlow.open`
    /// leaves an open list open.
    func openMenuForCapture() { open() }

    private func handleStateChange() {
        flow.hoverDelay = appState.hoverDelay
        flow.settings = appState.peekSettings
        setVisible(shouldShowMascot)
    }

    private func sessionsChanged(_ sessions: [Session]) {
        flow.sessionsChanged(sessions, now: Date())
        presenterChanged()
    }

    // MARK: - Pointer

    /// "Inside" is the cat and its capsule, or the open panel's shape — never the
    /// windows' transparent margins. Both windows' tracking areas call this, and a
    /// mouse-moved monitor while the panel is open, because the cursor crosses from
    /// one window to the other.
    private func pointerMoved() {
        let point = NSEvent.mouseLocation
        let onCat = catPanel.isVisible && catHitRect.contains(point)
        let onPanel = openPanel?.isVisible == true && openShapeRect.contains(point)
        if let bridge = peekBridge, !(openPanel != nil && bridge.contains(point)) { peekBridge = nil }
        if model.catHovered != onCat { model.catHovered = onCat }
        // As on the island (Part 2, `updateClickTarget`): the panel's window is its
        // shape plus the bloom's margin, and a click in the margin belongs to what lies
        // under it. Left alone while a button is down — the drag keeps its window.
        if let openPanel, NSEvent.pressedMouseButtons == 0, openPanel.ignoresMouseEvents == onPanel {
            openPanel.ignoresMouseEvents = !onPanel
        }
        // The bridge holds the list open, but takes no clicks: they belong to what
        // lies under its transparent band.
        reconcile(inside: onCat || onPanel || peekBridge != nil)
    }

    private var catHitRect: CGRect {
        let frame = catPanel.frame
        let canvas = FloatingLayout.catCanvasRect.union(FloatingLayout.capsuleRect)
        return CGRect(x: frame.minX + canvas.minX, y: frame.maxY - canvas.maxY, width: canvas.width, height: canvas.height)
    }

    private var openShapeRect: CGRect {
        guard let openPanel else { return .zero }
        return openPanel.frame.insetBy(dx: FloatingLayout.margin, dy: FloatingLayout.margin)
    }

    private func reconcile(inside: Bool) {
        guard inside != toldInside, NSEvent.pressedMouseButtons == 0 else { return }
        toldInside = inside
        if inside { flow.pointerEntered(now: Date()) } else { flow.pointerLeft(now: Date()) }
        presenterChanged()
    }

    // MARK: - Clicks and drags

    private func catClicked() {
        if flow.presentation == .expanded { flow.escape(now: Date()) } else { flow.open(now: Date()) }
        presenterChanged()
    }

    private func open() {
        flow.open(now: Date())
        presenterChanged()
    }

    /// A drag moves the cat, not an open list left behind.
    private func dragStarted() {
        flow.escape(now: Date())
        presenterChanged()
    }

    private func jumped() {
        // The jump activates its target; handing back afterwards would take the user
        // away from it.
        FocusReturn.forget()
        flow.jumped(now: Date())
        presenterChanged()
    }

    // MARK: - Presenter

    private func presenterChanged() {
        let new = flow.presentation
        if model.presentation != new {
            withAnimation(Motion.contentOut) { model.presentation = new }
        }
        if model.peekHold != flow.peekHold { model.peekHold = flow.peekHold }
        placeOpenPanel()
        armTimer()
    }

    private func listMeasured(_ height: CGFloat) {
        guard abs(height - listHeight) > 0.5 else { return }
        listHeight = height
        placeOpenPanel()
    }

    private enum OpenKind { case peek, listBelow, listAbove }

    /// The panel exists while the peek or the list is open; closed, it is released
    /// like the 0.4 details panel was — its previews and timelines must not run on.
    private func placeOpenPanel() {
        guard flow.presentation.isOpen, catPanel.isVisible, let screen = catPanel.screen ?? NSScreen.main else {
            shownKind = nil
            peekBridge = nil
            if openPanel != nil {
                closeOpenPanel()
                // The list closed under a cursor that may not move again (a jump,
                // Escape): without a fresh read the flow went on believing the pointer
                // was inside, held the next peek open, and after the hover delay the
                // dwell opened the list by itself. With `openPanel` gone this read
                // cannot come back here to close it again.
                pointerMoved()
            }
            return
        }
        let visible = screen.visibleFrame
        let room = FloatingLayout.panelPlacement(height: .greatestFiniteMagnitude, catWindow: catPanel.frame,
                                                 visibleFrame: visible).rect.height
        if model.listMaxHeight != room { model.listMaxHeight = room }
        let rect: CGRect
        let kind: OpenKind
        if case .peek = flow.presentation {
            // Its top at the resting capsule's top: the cat stands on it, and it is
            // never above the cat — a list left above a moment ago must not keep the
            // resting capsule under the cat's feet (`FloatingCatView`).
            rect = FloatingLayout.peekRect(catWindow: catPanel.frame, visibleFrame: visible)
            kind = .peek
        } else {
            let placement = FloatingLayout.panelPlacement(height: max(listHeight, 120), catWindow: catPanel.frame,
                                                          visibleFrame: visible)
            rect = placement.rect
            kind = placement.isAbove ? .listAbove : .listBelow
        }
        if model.panelIsAbove != (kind == .listAbove) { model.panelIsAbove = kind == .listAbove }
        // The first opening lays the list out before anyone has measured it: the
        // panel stays transparent at its guessed height until the real one arrives,
        // rather than showing a 120 pt panel that jumps a frame later. A peek's
        // height is fixed, and it keeps the list mounted, measured, under it.
        let shows = kind == .peek || listHeight > 0
        let change = shapeChange(to: kind, rect: rect, shows: shows)
        if kind != .listAbove {
            peekBridge = nil
        } else if shownKind == .peek {
            peekBridge = FloatingLayout.peekRect(catWindow: catPanel.frame, visibleFrame: visible).union(rect)
        }
        shownKind = shows ? kind : nil
        let frame = rect.insetBy(dx: -FloatingLayout.margin, dy: -FloatingLayout.margin)
        let isNew = openPanel == nil
        let moved = isNew || openPanel?.frame != frame
        // The window takes its new size before the view hears of the new shape, and
        // a new one is made at its frame, not at zero and then moved: a view laid out
        // with the new shape in a window of the old size took the resize into the
        // grow's spring, and the shape slid in from 200 pt too high, or from the
        // window's corner (both recorded at 60 fps).
        if let openPanel, moved { openPanel.setFrame(frame, display: false) }
        // A size that did not change is not sent again: the list measured under a
        // growing peek would otherwise stop the spring where it was.
        if change != .none || model.panelShape.size != rect.size {
            model.panelShape = PanelShape(size: rect.size, change: change, revision: shapeRevision)
        }
        let panel = openPanel ?? makeOpenPanel(frame: frame)
        openPanel = panel
        panel.alphaValue = shows ? 1 : 0
        if !panel.isVisible { panel.orderFrontRegardless() }
        startPointerMonitor()
        // The shape moved under a still cursor: where clicks go (`ignoresMouseEvents`)
        // and "inside" are read again, as the island does after a resize
        // (`resyncPointer`). A second pass finds the frame unchanged and stops. This
        // is also the read decision 3 asks for: a peek that appears under a resting
        // cursor counts as hover, pauses and turns into the list after the delay.
        if moved { pointerMoved() }
    }

    /// Spec §9, "on the §5.2 springs": a shape appearing grows from the resting
    /// capsule, or, for a list above the cat, from a capsule-sized strip at its bottom
    /// centre; a peek turning into a list below the cat springs from the peek, whose
    /// top and sides it shares. Everything else — a list measured again, a peek
    /// replacing a peek — takes its size at once.
    private func shapeChange(to kind: OpenKind, rect: CGRect, shows: Bool) -> PanelShape.Change {
        guard shows, kind != shownKind else { return .none }
        if shownKind == .peek, kind == .listBelow { return .spring }
        shapeRevision += 1
        let capsule = FloatingLayout.capsule
        if kind == .listAbove {
            return .grow(from: CGRect(x: (rect.width - capsule.width) / 2, y: rect.height - capsule.height,
                                      width: capsule.width, height: capsule.height))
        }
        let rest = FloatingLayout.capsuleOnScreen(catWindow: catPanel.frame)
        return .grow(from: CGRect(x: rest.minX - rect.minX, y: rect.maxY - rest.maxY,
                                  width: rest.width, height: rest.height))
    }

    private func makeOpenPanel(frame: NSRect) -> OverlayPanel {
        // `allowsKey`: the list holds buttons, which need a window that can be key. It
        // becomes key only on a mouse-down inside it — never from hover.
        let panel = OverlayPanel(contentRect: frame, allowsKey: true)
        panel.becomesKeyOnlyOnClick = true
        panel.level = .floating
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        // Decision 1, as on the island: a click inside activates CodeCat, so Escape
        // reaches the panel; `closeOpenPanel()` hands activation back. A click that
        // jumped has closed the list by the time this runs (after the mouse-up): the
        // jump's target takes activation, not CodeCat.
        panel.onActivatingClick = { [weak self] in
            guard let self, self.flow.presentation.isOpen else { return }
            FocusReturn.remember()
            NSApp.activate()
        }
        let pointer = PointerTracker()
        let hosting = EscapeHostingView(rootView: FloatingPanelView(appState: appState, model: model, pointer: pointer))
        // The window's size is the controller's decision.
        hosting.sizingOptions = []
        hosting.pointer = pointer
        hosting.onPointer = { [weak self] _ in self?.pointerMoved() }
        hosting.onEscape = { [weak self] in
            self?.flow.escape(now: Date())
            self?.presenterChanged()
        }
        panel.contentView = hosting
        panel.ignoresMouseEvents = true
        // Escape reaches `keyDown` only through the first responder, and a click that
        // made the panel key leaves one of SwiftUI's own views there (Part 2's island).
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: panel,
                                                             queue: .main) { [weak panel, weak hosting] _ in
            guard let panel, let hosting else { return }
            panel.makeFirstResponder(hosting)
        }
        return panel
    }

    private func closeOpenPanel() {
        guard let panel = openPanel else { return }
        // Decision 1: activation goes back to the app the user was in.
        FocusReturn.handBack()
        panel.orderOut(nil)
        openPanel = nil
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
        stopPointerMonitor()
    }

    /// While the list is open the cursor moves between two windows and the space
    /// around them; the tracking areas see it inside the windows, and a global
    /// mouse-moved monitor sees it outside them while another app is active.
    private func startPointerMonitor() {
        guard pointerMonitor == nil else { return }
        pointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            DispatchQueue.main.async { self?.pointerMoved() }
        }
    }

    private func stopPointerMonitor() {
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
        pointerMonitor = nil
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

    /// As on the island: a button held when the hover dwell ends — a click on the
    /// cat that began just before the deadline, or a drag — must not end in an open
    /// list. Opened at the deadline, the click's own mouse-up closed it again (`onTap`
    /// on an open list), a flash. It counts as the pointer leaving; the mouse-up then
    /// opens the list on the click, or the cursor is read again after a drag.
    ///
    /// A peek under the cursor dwells the same way (decision 3), and a press held on
    /// it is a click on its pill or its line — or on the cat, whose mouse-up would
    /// close the list the dwell opened. Only while the cursor is inside, where the
    /// deadline is the dwell's: outside it is the hold's end, which must still close
    /// the peek under a held button.
    private func deadlineReached() {
        let dwelling: Bool
        switch flow.presentation {
        case .inhaled: dwelling = true
        case .peek: dwelling = toldInside
        case .compact, .expanded: dwelling = false
        }
        if dwelling, NSEvent.pressedMouseButtons != 0 {
            toldInside = false
            flow.pointerLeft(now: Date())
            waitForMouseUp()
            presenterChanged()
            return
        }
        flow.tick(now: Date())
        presenterChanged()
    }

    /// The held button comes up anywhere — on the cat, on the peek, off both — so
    /// the monitors are global as well as local; the cursor is read then, as on the
    /// island (`IslandController.waitForMouseUp`). A still cursor on the peek sends
    /// no event of its own.
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
        pointerMoved()
    }

    // MARK: - Position

    func windowDidMove(_ notification: Notification) {
        guard (notification.object as? NSPanel) === catPanel else { return }
        let anchor = FloatingLayout.anchor(catWindowOrigin: catPanel.frame.origin)
        UserDefaults.standard.set(MascotLayout.storedValue(for: anchor), forKey: Self.positionKey)
    }

    private static func savedAnchor() -> NSPoint? {
        let defaults = UserDefaults.standard
        return MascotLayout.storedOrigin(current: defaults.array(forKey: positionKey) as? [Double],
                                         legacy: defaults.array(forKey: legacyPositionKey) as? [Double])
    }

    /// Guards against a saved position from a display that is no longer connected:
    /// if the remembered rect doesn't intersect any currently attached screen, fall
    /// back to the default corner instead of stranding the cat off-screen.
    private static func validated(_ anchor: NSPoint?) -> NSPoint? {
        guard let anchor else { return nil }
        return MascotLayout.isOnScreen(origin: anchor, screens: NSScreen.screens.map(\.visibleFrame)) ? anchor : nil
    }

    private static func defaultAnchor() -> NSPoint {
        guard let screen = NSScreen.main else { return NSPoint(x: 100, y: 100) }
        return MascotLayout.defaultOrigin(visibleFrame: screen.visibleFrame, inset: 24)
    }
}

/// Hosts the cat and implements click-vs-drag itself instead of combining SwiftUI's
/// `.onTapGesture` with `NSWindow.isMovableByWindowBackground`.
///
/// Those two don't compose: SwiftUI's tap gesture on AppKit is implemented by having
/// the hosting view handle `mouseDown`/`mouseUp` itself, which means the event never
/// reaches `NSWindow`'s "move by background" fallback (that fallback only fires when
/// the clicked view does *not* handle the mouse event) — a cat that opens its list
/// but can never be dragged. Tracking mouseDown/mouseDragged/mouseUp directly, and
/// treating anything past a small movement threshold as a drag rather than a tap,
/// gives both behaviors reliably in the same view.
///
/// Its hit area is the whole window; `FloatingController.catHitRect` decides what
/// counts as the cat for hover.
private final class CatHostingView: NSHostingView<FloatingCatView> {
    var onTap: (() -> Void)?
    /// The cat window's tracking area: entered, moved (true) and exited (false). The
    /// controller reads the cursor itself; SwiftUI's own hover is silent here, as the
    /// window is never key and the app usually inactive, and only an `.activeAlways`
    /// tracking area reports hover in that situation.
    var onHover: ((Bool) -> Void)?
    /// The moment a press became a drag: the list closes, the cat moves.
    var onDragStart: (() -> Void)?
    /// Every mouse-up, after `onTap`.
    var onMouseUp: (() -> Void)?
    /// Only this view's own area is replaced on update: `NSHostingView` registers
    /// tracking areas of its own for SwiftUI, and those are not ours to remove.
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    /// No cursor is set here, deliberately. This window is a `.nonactivatingPanel`
    /// that can never become key, and the window server does not honour a cursor
    /// set from a non-key window of an inactive app: the tracking area fires (checked
    /// with a log), `NSCursor.pointingHand.set()` runs, and the arrow stays. So the
    /// lift is the only hover feedback the cat has.
    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }

    override func mouseMoved(with event: NSEvent) {
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
    }

    private var dragStartScreenPoint: NSPoint = .zero
    private var dragStartWindowOrigin: NSPoint = .zero
    private var didDrag = false
    /// Past 3 pt a press is a drag: a hand that twitches while clicking still clicks.
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
            onDragStart?()
        }
        if didDrag {
            window.setFrameOrigin(NSPoint(x: dragStartWindowOrigin.x + dx,
                                          y: dragStartWindowOrigin.y + dy))
        }
    }

    override func mouseUp(with event: NSEvent) {
        if !didDrag { onTap?() }
        didDrag = false
        onMouseUp?()
    }
}
