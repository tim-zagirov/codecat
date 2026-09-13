import SwiftUI
import CodeCatCore

/// The floating mode's panel. All of its content moved to `SessionListView` and
/// `SettingsSectionView`; what is left here is the heading, the background and the
/// size — the things that distinguish this panel from the island menu.
struct DetailsPanelView: View {
    @ObservedObject var appState: AppState

    /// Called after a jump is started, so the panel can close itself: the user asked
    /// to be somewhere else.
    var onJump: () -> Void = {}

    /// See `PointerTracker`: the panel is key and SwiftUI's hover would work here,
    /// but the island's menu shares every row and tile with this panel, and one
    /// hover mechanism for both is the only way to keep them identical.
    let pointer: PointerTracker

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CodeCat").font(.headline)
            SessionListView(appState: appState, onJump: onJump)
            Divider()
            SettingsSectionView(appState: appState)
        }
        .font(.system(size: 12))
        .padding(14)
        .frame(width: 290, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .environmentObject(pointer)
    }
}
