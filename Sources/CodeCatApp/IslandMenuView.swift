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
///
/// Ширину задаёт остров, а не вид: две чёрные формы разной ширины дают на стыке
/// видимый уступ, в котором проступают обои.
struct IslandMenuView: View {
    @ObservedObject var appState: AppState
    let level: IslandMenuLevel
    let width: CGFloat
    /// Меню закрывается: та же пружина, что и на раскрытии, но в обратную сторону.
    /// Раньше закрытие было мгновенным — форма просто исчезала, и раскрытие с
    /// закрытием читались как два разных механизма. Само окно уводится с экрана
    /// уже после того, как анимация доехала; этим распоряжается `IslandController`.
    var isCollapsing: Bool = false
    var onJump: () -> Void = {}

    /// Высота уже отрисованного содержимого и признак того, что раскрытие
    /// состоялось. Пара нужна вместе: пока высота неизвестна, раскрывать нечего,
    /// а если запустить анимацию раньше, она поедет от нуля к нулю и содержимое
    /// появится рывком.
    @State private var contentHeight: CGFloat = 0
    @State private var revealed = false

    /// Пружина без отскока. Отскок в строке меню читается не как живость, а как
    /// дребезг: форма стоит вплотную к кромке экрана, и любое перелетание за
    /// конечную высоту выглядит браком.
    static let reveal = Animation.spring(response: 0.28, dampingFraction: 1.0)

    /// Сколько ждать, прежде чем убирать окно: пружина без отскока укладывается в
    /// это время с запасом. Отдельной константой, потому что её знает и контроллер.
    static let revealDuration: TimeInterval = 0.32

    var body: some View {
        content
            .background(GeometryReader { proxy in
                Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
            })
            // Маска, а не масштаб: масштаб растянул бы текст по вертикали, и
            // раскрытие выглядело бы как резиновая надпись, а не как форма,
            // выезжающая из выреза.
            //
            // И маска именно скруглённая, а не прямоугольная. С прямоугольной
            // выезжающая полоска всё время идёт с квадратным низом, а скругление
            // возникает только в самом конце, когда маска доехала до полной
            // высоты. Вместе с островом, который в этот же момент распрямляет свои
            // нижние углы, это читается не как «форма выдвигается», а как
            // «появился прямоугольник». Скругление обязано ехать вниз вместе с
            // нижней кромкой — тогда из выреза выдвигается форма, а не вырастает
            // коробка. Радиус в самой фигуре зажат половиной высоты, поэтому на
            // первых пунктах выезда кромка скругляется соразмерно, а не рисует
            // огрызок дуги.
            .mask(alignment: .top) {
                BottomRoundedRectangle(radius: IslandLayout.cornerRadius)
                    .frame(height: revealed ? contentHeight : 0)
            }
            .onChange(of: isCollapsing) { _, collapsing in
                guard collapsing else { return }
                withAnimation(Self.reveal) { revealed = false }
            }
            .onPreferenceChange(ContentHeightKey.self) { height in
                guard height > 0 else { return }
                guard !isCollapsing else { return }
                if revealed {
                    // Переход «короткое → полное»: высота меняется, а раскрытие
                    // уже состоялось. Той же пружиной доезжаем до новой высоты,
                    // не схлопывая и не пересобирая список сессий.
                    withAnimation(Self.reveal) { contentHeight = height }
                } else {
                    withAnimation(Self.reveal) {
                        contentHeight = height
                        revealed = true
                    }
                }
            }
    }

    private var content: some View {
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
        .background(Color.black)
        .clipShape(BottomRoundedRectangle(radius: IslandLayout.cornerRadius))
        .environment(\.menuStyle, .island)
        // Содержимое написано под системную тему: на чёрном фоне ему надо
        // считать себя тёмной темой, иначе системные элементы (переключатель
        // вида, тумблеры) окажутся светлыми плашками на чёрном.
        .environment(\.colorScheme, .dark)
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
