import AppKit

/// Gives activation back to the app the user was in. CodeCat is an accessory app:
/// when it activates for a window the user asked for — Settings, a hooks dialog, a
/// click in the open island (Tim, 2026-09-30) — and that window goes away, macOS
/// leaves CodeCat active with no window, and whatever the user types next goes
/// nowhere. So the app that was frontmost is remembered on the way in and activated
/// again on the way out.
enum FocusReturn {
    private static var previous: NSRunningApplication?

    /// Remember the frontmost app, unless it is CodeCat already (a second window
    /// opened from the first must not forget where the user came from).
    static func remember() {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        previous = front
    }

    /// The next activation is someone else's — a jump activates its target, and
    /// handing back after it would take the user away from where they jumped to.
    static func forget() { previous = nil }

    /// Activate the remembered app, once no CodeCat window the user is working in is
    /// left open. `closing` is the window on its way out, still visible while its
    /// `windowWillClose` runs.
    static func handBack(excluding closing: NSWindow? = nil) {
        let stillOpen = NSApp.windows.contains { $0 !== closing && $0.isVisible && $0.canBecomeMain }
        guard !stillOpen, let app = previous else { return }
        previous = nil
        guard NSApp.isActive else { return }
        NSApp.yieldActivation(to: app)
        app.activate(from: .current, options: [])
    }
}
