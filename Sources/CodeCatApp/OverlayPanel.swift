import AppKit

/// A borderless, non-activating floating panel: the island, the floating cat and the
/// floating cat's list. `.nonactivatingPanel` lets it accept mouse/keyboard input without
/// ever bringing CodeCat to the front by itself: hover and the panel's own key status
/// never take focus from the user's app. The island's and the list's owners are the
/// exception, by choice — they activate CodeCat on a click inside
/// (`onActivatingClick`) and hand activation back when they close.
///
/// `allowsKey` is per-instance rather than hardcoded because the cat and the list
/// need different answers: the cat must NEVER take key status (it can be tapped
/// at any time without disturbing whatever the user is doing), while the list
/// needs to become key so its `Toggle`/`Button` controls actually receive clicks and
/// keyboard interaction — an AppKit panel that can never become key routinely fails to
/// deliver events to standard controls hosted inside it. Because the panel keeps
/// `.nonactivatingPanel`, becoming key still does not activate the app or steal focus
/// from whatever application was frontmost (this is the same mechanism `NSColorPanel`/
/// `NSFontPanel` rely on).
class OverlayPanel: NSPanel {
    private let allowsKey: Bool

    /// Routes a click that lands in a panel which is not key.
    ///
    /// AppKit spends such a click on making the window key, and only delivers it to
    /// the view as well if that view answers `acceptsFirstMouse` with true. It asks
    /// the view the click LANDS on, never an ancestor — and the views SwiftUI builds
    /// underneath a hosting view (`PlatformGroupContainer`, `NSClipView` inside a
    /// `ScrollView`, …) all answer false. Overriding `acceptsFirstMouse` on the
    /// hosting view therefore changed nothing, and chasing SwiftUI's private view
    /// classes one at a time is a game with no end.
    ///
    /// The island's menu opened by hover is exactly this case: it is deliberately not
    /// key (a key panel would take keystrokes from whatever the user is typing in),
    /// so every session row in it needed clicking twice — the first click vanished
    /// into taking key status. Measured live, with the panel's own events logged:
    /// `sendEvent down key=false` → `hitTest -> PlatformGroupContainer afm=false` →
    /// nothing else; no `mouseDown`, no tap.
    ///
    /// Taking key status here, before `super.sendEvent`, makes the window key first
    /// and the very same click is then routed normally — verified by the same log:
    /// `down key=false -> makeKey` → `mouseDown` → the row's tap. Nothing about focus
    /// changes: AppKit was about to make this panel key with that click anyway. Panels
    /// that may never become key (the cat) are untouched.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, allowsKey {
            activatesOnMouseUp = onActivatingClick != nil && !NSApp.isActive
            if !isKeyWindow {
                clickGrantsKey = true
                makeKey()
            }
        }
        super.sendEvent(event)
        if event.type == .leftMouseUp, activatesOnMouseUp {
            activatesOnMouseUp = false
            DispatchQueue.main.async { [weak self] in self?.onActivatingClick?() }
        }
    }

    /// Tim, 2026-09-30: a click activates CodeCat, so Escape and the keyboard reach
    /// the panel. Key status alone did not hold: the window server handed it back to
    /// the frontmost app ~35 ms after the click (Escape failed 5 of 5 with Finder in
    /// front). The owner remembers where the user came from and activates.
    ///
    /// Called once the click is over — after its mouse-up has been handled — and
    /// only for a click that began while CodeCat was inactive, so the frontmost app
    /// can still be read. Activating during the mouse-down lost the keyboard in 5 of
    /// 8 runs (logged: AppKit reported CodeCat active with the panel key, and the
    /// Escape that followed never reached the app), and with
    /// `activate(ignoringOtherApps:)` in 3 of 4; after the mouse-up it held in 4 of 4.
    var onActivatingClick: (() -> Void)?
    private var activatesOnMouseUp = false

    /// The island's panel may become key only from a click in it (spec §2: the
    /// island never takes focus from the terminal). Without this, AppKit made it key
    /// by itself at launch — `-[NSApplication _sendFinishLaunchingNotification]`
    /// picks the first window that can be key — and keystrokes went to the island
    /// until the user clicked somewhere else. The click that grants key status is
    /// the mouse-down in `sendEvent` above; resigning takes it back.
    var becomesKeyOnlyOnClick = false
    private var clickGrantsKey = false

    override var canBecomeKey: Bool { allowsKey && (!becomesKeyOnlyOnClick || clickGrantsKey) }

    override func resignKey() {
        super.resignKey()
        clickGrantsKey = false
    }

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
        // `.stationary` keeps the panel on screen through Mission Control (Exposé),
        // where every other window slides away; without it the cat vanished the
        // moment the user pinched to see their desktops. Verified by screenshot: two
        // otherwise identical panels, only the one with the flag survived.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        // Dragging is implemented by hand in `CatHostingView` (FloatingController), so the
        // window itself never needs to move the frame on a plain background click.
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
    }
}
