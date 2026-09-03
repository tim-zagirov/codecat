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
    }
}
