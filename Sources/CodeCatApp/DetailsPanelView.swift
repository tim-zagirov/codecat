import SwiftUI
import CodeCatCore

/// Панель плавающего режима. Всё содержимое переехало в `SessionListView` и
/// `SettingsSectionView`, здесь остались только заголовок, фон и размер —
/// то, чем эта панель отличается от меню острова.
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
