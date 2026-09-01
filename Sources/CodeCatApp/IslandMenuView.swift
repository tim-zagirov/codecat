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

/// Содержимое меню острова — и только содержимое.
///
/// Ни фона, ни формы, ни анимации раскрытия здесь нет: всё это принадлежит
/// `IslandView`, где остров и меню лежат на одной подложке и обрезаются одним
/// силуэтом. Пока меню было отдельным окном со своим чёрным фоном и своей
/// скруглённой маской, шов на стыке можно было только прятать — совпадением ширин
/// и обнулением радиуса у острова. Одна подложка убирает шов как явление.
///
/// Единственное, что вид сообщает наружу, — свою высоту: по ней `IslandView`
/// знает, до какой высоты растить силуэт.
struct IslandMenuView: View {
    @ObservedObject var appState: AppState
    let level: IslandMenuLevel
    let width: CGFloat
    var onJump: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SessionListView(appState: appState, onJump: onJump)
            if level == .full {
                MenuSeparator()
                SettingsSectionView(appState: appState)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(width: width, alignment: .leading)
        .environment(\.menuStyle, .island)
        // Содержимое написано под системную тему: на чёрном фоне ему надо
        // считать себя тёмной темой, иначе системные элементы (переключатель
        // вида, тумблеры) окажутся светлыми плашками на чёрном.
        .environment(\.colorScheme, .dark)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: IslandContentHeightKey.self, value: proxy.size.height)
        })
    }
}

/// Высота содержимого меню, измеренная по факту вёрстки. Не `private`: её читает
/// `IslandView`, которому и принадлежит анимация раскрытия.
struct IslandContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
