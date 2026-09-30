import CoreGraphics

/// "A full-screen app covers this screen", from the window list — spec §6.2's rule
/// for hiding the island. The menu-bar half of the spec's test is not used (decision
/// 12): `NSMenu.menuBarVisible()` describes CodeCat's own menu bar, which an
/// accessory app never shows. Pure, so the rule is tested without a full-screen app.
public enum FullScreen {
    public struct Window: Equatable, Sendable {
        public let ownerPID: Int32
        public let layer: Int
        /// In window-list coordinates: origin at the main screen's top-left, y down.
        public let bounds: CGRect
        public init(ownerPID: Int32, layer: Int, bounds: CGRect) {
            self.ownerPID = ownerPID; self.layer = layer; self.bounds = bounds
        }
    }

    /// Whether the frontmost app has a normal-level window exactly as large as
    /// `screen` — what a full-screen window is, and what no ordinary window can be,
    /// since the menu bar takes the top of the screen.
    public static func covers(screen: CGRect, windows: [Window], frontmostPID: Int32?) -> Bool {
        guard let pid = frontmostPID else { return false }
        return windows.contains { $0.ownerPID == pid && $0.layer == 0 && $0.bounds.equalTo(screen) }
    }

    /// An `NSScreen.frame` in the window list's coordinates.
    public static func cgRect(forScreenFrame frame: CGRect, mainScreenHeight: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: mainScreenHeight - frame.maxY, width: frame.width, height: frame.height)
    }
}
