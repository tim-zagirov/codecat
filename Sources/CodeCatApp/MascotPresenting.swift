import Foundation

/// One way of showing the mascot. There are two implementations — the floating
/// window (`OverlayController`) and the island in the notch (`IslandController`) —
/// and exactly one lives on screen at a time: `AppDelegate` destroys the previous
/// one when the mode changes.
///
/// The protocol is deliberately narrow. Everything else — position, hover, menu —
/// differs between the modes far too much for a shared interface over it to be
/// anything but an invention.
protocol MascotPresenting: AnyObject {
    /// Show or hide the whole mode, menu included.
    func setVisible(_ visible: Bool)

    /// Opens the mascot's menu without a click.
    ///
    /// Only `--demo` calls this, and only so `scripts/capture-screenshots.sh` can
    /// photograph the session list and the skin grid — both of which are otherwise
    /// reachable only by moving a real pointer onto a window that screen-control
    /// tools cannot see (the app is `LSUIElement`). It is a separate method rather
    /// than a synthesized click for exactly that reason: there is nothing to
    /// synthesize a click *onto* from outside.
    func openMenuForCapture()
}
