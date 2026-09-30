import AppKit
import SwiftUI
import CodeCatCore

/// The one Settings window (spec §8): 720 × 520, titled and closable, not resizable.
/// Opening it activates CodeCat — the user asked for a window — and closing it hands
/// activation back to the app they came from (`FocusReturn`).
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let appState: AppState
    private let selection = SettingsSelection()
    private var window: NSWindow?

    init(appState: AppState) {
        self.appState = appState
    }

    func show(_ pane: SettingsPane? = nil) {
        if let pane { selection.pane = pane }
        let window = self.window ?? makeWindow()
        self.window = window
        FocusReturn.remember()
        // `NSApp.activate()` alone leaves the window behind the frontmost app's own
        // windows — the same reason `AppState.runInFront` orders its alerts with
        // `orderFrontRegardless()` rather than trusting activation to reorder them.
        // CodeCat is an accessory app with no recent user event of its own to point
        // to (the "•••" click lands on the island's window, not this one), so
        // activation is a request the window server is free to defer.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// `--demo-settings`: a fixed place on the main screen — 200 pt from its left edge,
    /// 120 pt from its top — so a capture can crop the window at a known rectangle.
    func placeForCapture() {
        guard let window, let screen = NSScreen.main else { return }
        window.setFrameTopLeftPoint(NSPoint(x: screen.frame.minX + 200, y: screen.frame.maxY - 120))
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = L10n.t("settings.window.title", "CodeCat Settings")
        window.isReleasedWhenClosed = false
        window.delegate = self
        let hosting = NSHostingView(rootView: SettingsView(appState: appState, selection: selection))
        // The window's size is fixed (spec §8); the hosting view must not impose its own.
        hosting.sizingOptions = []
        window.contentView = hosting
        window.center()
        return window
    }

    /// Released, not hidden: the Cat pane animates every skin's preview, and a hidden
    /// window would keep them all running for the rest of the app's life.
    func windowWillClose(_ notification: Notification) {
        let closing = window
        window = nil
        FocusReturn.handBack(excluding: closing)
    }
}
