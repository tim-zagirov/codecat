import SwiftUI
import CodeCatCore

/// Содержимое острова: кот в левом крыле, счётчик в правом, между ними — дырка
/// под физический вырез.
///
/// Крылья одинаковой ширины, и это главное правило композиции. Кот — объект с
/// габаритом, счётчик — штрих; уравнять их кеглем или цветом нельзя, только
/// геометрией. Пока крыло считалось по спрайту, всё чёрное пятно уезжало от
/// центра экрана и перевешивало котом.
struct IslandView: View {
    @ObservedObject var appState: AppState
    let notchWidth: CGFloat
    let wingWidth: CGFloat
    let spriteSize: CGSize
    /// Высота полосы острова — она же высота выреза.
    let height: CGFloat
    /// Какое меню показывать под островом. `nil` — только полоса.
    var menuLevel: IslandMenuLevel?
    /// Меню закрывается: силуэт едет обратно к высоте острова той же пружиной.
    /// Содержимое при этом остаётся смонтированным — иначе схлопывать было бы
    /// нечего, — и снимается уже после того, как анимация доехала.
    var isCollapsing: Bool = false
    var onJump: () -> Void = {}

    /// Высота содержимого меню, измеренная по факту вёрстки, и признак того, что
    /// раскрытие состоялось. Пара нужна вместе: пока высота неизвестна, раскрывать
    /// нечего, а запуск анимации раньше поехал бы от нуля к нулю.
    @State private var menuHeight: CGFloat = 0
    @State private var revealed = false

    /// Пружина без отскока. Отскок в строке меню читается не как живость, а как
    /// дребезг: форма стоит вплотную к кромке экрана, и любое перелетание за
    /// конечную высоту выглядит браком.
    static let reveal = Animation.spring(response: 0.28, dampingFraction: 1.0)

    /// Сколько ждать, прежде чем убирать содержимое меню и сжимать окно: пружина
    /// без отскока укладывается в это время с запасом. Знает и контроллер.
    static let revealDuration: TimeInterval = 0.32

    /// Ширина корпуса — без места под галтели.
    private var bodyWidth: CGFloat { 2 * wingWidth + notchWidth }

    /// До какой высоты открыт силуэт прямо сейчас. Это и есть вся анимация: у
    /// одной формы растёт высота, а её скруглённая нижняя кромка едет вниз вместе
    /// с ней. Ни шва, ни второй формы, ни подгонки радиусов друг под друга.
    private var revealedHeight: CGFloat { height + (revealed ? menuHeight : 0) }

    var body: some View {
        VStack(spacing: 0) {
            strip
            if let menuLevel {
                IslandMenuView(appState: appState, level: menuLevel,
                               width: bodyWidth, onJump: onJump)
            }
        }
        // Место под галтели у кромки экрана: они лежат снаружи корпуса, поэтому
        // окно шире корпуса на `edgeRadius` с каждой стороны, а содержимое остаётся
        // ровно в корпусе. См. `IslandLayout.edgeRadius`.
        .padding(.horizontal, IslandLayout.edgeRadius)
        .background(Color.black)
        // Одна маска на остров и меню разом — та самая общая подложка. Форма
        // рисуется маской, а не обрезкой фона: `clipShape` резал бы прямоугольник
        // фона, а закрашивать надо в том числе площадь снаружи корпуса (галтели).
        .mask(alignment: .top) {
            IslandShape(bottomRadius: IslandLayout.cornerRadius)
                .frame(height: revealedHeight)
        }
        .onPreferenceChange(IslandContentHeightKey.self) { measured in
            guard measured > 0 else { return }
            if revealed {
                // Переход «короткое → полное»: раскрытие уже состоялось, той же
                // пружиной доезжаем до новой высоты, не схлопывая список сессий.
                withAnimation(Self.reveal) { menuHeight = measured }
            } else {
                menuHeight = measured
                guard menuLevel != nil, !isCollapsing else { return }
                withAnimation(Self.reveal) { revealed = true }
            }
        }
        .onChange(of: isCollapsing) { _, collapsing in
            guard collapsing else { return }
            withAnimation(Self.reveal) { revealed = false }
        }
        .onChange(of: menuLevel == nil) { _, gone in
            // Содержимое сняли — сбрасываем без анимации: силуэт уже стоит на
            // высоте острова, анимировать нечего.
            guard gone else { return }
            revealed = false
            menuHeight = 0
        }
    }

    /// Полоса острова: кот в левом крыле, счётчик в правом, между ними — дырка
    /// под физический вырез.
    private var strip: some View {
        HStack(spacing: 0) {
            cat
                .frame(width: wingWidth, height: height)
            // Физический вырез: сюда ничего не кладём, там дырка в матрице.
            Color.clear
                .frame(width: notchWidth, height: height)
            counter
                .frame(width: wingWidth, height: height)
        }
        .frame(height: height)
    }

    private var cat: some View {
        MascotView(skin: appState.skin,
                   status: appState.store.aggregate,
                   sessionCount: appState.store.badgeCount,
                   drawingSize: spriteSize,
                   canvasSize: CGSize(width: spriteSize.width, height: height),
                   showsBadge: false,
                   since: appState.statusSince,
                   onLoadFailure: { [appState] skin in appState.reportSkinLoadFailure(skin) })
    }

    /// Счётчик в капсуле, а не голой цифрой.
    ///
    /// Капсула здесь несёт вес, а не украшает: одиночный глиф против плотного
    /// спрайта читается как штрих, и правая сторона визуально проваливается.
    /// Ограниченная форма уравнивает стороны. Подпись («1 сессия», «3 сессии»)
    /// отпала по другой причине: русское счётное слово склоняется по числу, и
    /// ширина капсулы прыгала бы при каждом изменении счёта.
    @ViewBuilder
    private var counter: some View {
        let count = appState.store.badgeCount
        if count > 0 {
            HStack(spacing: 4) {
                statusDot
                // Цифра всегда белая: состояние несёт точка. Красная цифра рядом
                // с красной точкой — это два сигнала об одном и том же.
                Text("\(count)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .monospacedDigit()
            }
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(Color.white.opacity(0.10)))
        } else {
            // Считать нечего — но остров остаётся на месте, иначе на него нельзя
            // будет навести мышь. Точка без капсулы: держать пустую форму не за чем.
            Circle()
                .fill(Color.white.opacity(0.35))
                .frame(width: 6, height: 6)
        }
    }

    /// Цвет точки повторяет цвета статусов в списке сессий один в один: точка на
    /// острове и точка в строке меню обязаны значить одно и то же, иначе система
    /// цветов распадается на две.
    private var statusDot: some View {
        Circle()
            .fill(color(for: appState.store.aggregate))
            .frame(width: 6, height: 6)
    }

    private func color(for status: AggregateStatus) -> Color {
        switch status {
        case .working: return .green
        case .waiting: return .orange
        case .done: return .blue
        case .problem: return .red
        case .sleeping: return Color.white.opacity(0.35)
        }
    }
}

/// Силуэт острова: вогнутые галтели у верхней кромки экрана, скруглённые углы
/// снизу. Вся геометрия — в `IslandLayout.silhouettePath`, здесь только обёртка для
/// SwiftUI.
///
/// `animatableData` — нижний радиус: он меняется при раскрытии меню, и без этого
/// углы щёлкали бы мгновенно, пока сама форма едет пружиной. Галтели у кромки не
/// анимируются: кромка экрана никуда не двигается.
struct IslandShape: Shape {
    var bottomRadius: CGFloat

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        Path(IslandLayout.silhouettePath(in: rect, bottomRadius: bottomRadius))
    }
}
