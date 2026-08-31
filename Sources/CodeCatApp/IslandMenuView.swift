import SwiftUI
import CodeCatCore

/// Насколько подробное меню показывается.
enum IslandMenuLevel {
    /// Наведение: только список сессий. Мышь могла заехать на остров случайно,
    /// и полэкрана настроек в ответ на это — слишком.
    case short
    /// Клик: всё, что есть в панели плавающего режима.
    case full
}

/// Меню острова. То же содержимое, что и в панели плавающего режима, но на
/// абсолютно чёрном фоне: чёрное меню под чёрной плашкой читается как одно целое
/// с физическим вырезом, а любой материал или прозрачность выдали бы шов.
struct IslandMenuView: View {
    @ObservedObject var appState: AppState
    let level: IslandMenuLevel
    var onJump: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SessionListView(appState: appState, onJump: onJump)
            if level == .full {
                separator
                SettingsSectionView(appState: appState)
            }
        }
        .font(.system(size: 12))
        .padding(14)
        .frame(width: 290, alignment: .leading)
        .background(Color.black)
        .clipShape(BottomRoundedRectangle(radius: IslandLayout.cornerRadius))
        // Содержимое написано под системную тему: на чёрном фоне оно обязано
        // считать себя тёмной темой, иначе `.secondary` и `.tertiary` окажутся
        // чёрными на чёрном при светлом оформлении системы.
        .environment(\.colorScheme, .dark)
    }

    /// Системный `Divider` на чистом чёрном почти не виден.
    private var separator: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(height: 1)
    }
}
