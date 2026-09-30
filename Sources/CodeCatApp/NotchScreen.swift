import AppKit
import CodeCatCore

/// Whether any screen has a notch the island can be built around — the same test
/// `IslandController.computeGeometry()` uses, so the Settings window never offers the
/// island where it cannot appear.
enum NotchScreen {
    static var exists: Bool {
        NSScreen.screens.contains { screen in
            IslandLayout.notchRect(auxLeft: screen.auxiliaryTopLeftArea,
                                   auxRight: screen.auxiliaryTopRightArea) != nil
        }
    }
}
