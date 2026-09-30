import AppKit
import CodeCatCore

/// Tells the island when a full-screen app covers the notch screen. Re-checked when
/// the Space changes and when an app activates — the two ways a full-screen window
/// comes to the front — after the Space animation settles, and logged, because
/// whether this detection holds up is a manual check (spec §6.2). The first answer
/// is logged too, so the check can see the watcher running on an ordinary desktop.
final class FullScreenWatcher {
    private(set) var isFullScreen = false
    /// The notch screen; set by the controller whenever its geometry changes.
    var screen: NSScreen?
    private let onChange: (Bool) -> Void
    private let log: DiagnosticLog
    private var observers: [NSObjectProtocol] = []
    private var hasChecked = false

    init(log: DiagnosticLog, onChange: @escaping (Bool) -> Void) {
        self.log = log
        self.onChange = onChange
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.check() }
            })
        }
    }

    deinit { observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver) }

    func check() {
        guard let screen, let main = NSScreen.screens.first else { return }
        let rect = FullScreen.cgRect(forScreenFrame: screen.frame, mainScreenHeight: main.frame.height)
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let windows = list.compactMap { info -> FullScreen.Window? in
            guard let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return nil }
            return FullScreen.Window(ownerPID: pid, layer: layer, bounds: rect)
        }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // A click in the open island activates CodeCat itself; its windows say nothing
        // about the app underneath, so the last answer stands until that app is back.
        guard front != ProcessInfo.processInfo.processIdentifier else { return }
        let full = FullScreen.covers(screen: rect, windows: windows, frontmostPID: front)
        let first = !hasChecked
        hasChecked = true
        guard full != isFullScreen || first else { return }
        log.write("full screen on the notch screen: \(full)")
        guard full != isFullScreen else { return }
        isFullScreen = full
        onChange(full)
    }
}
