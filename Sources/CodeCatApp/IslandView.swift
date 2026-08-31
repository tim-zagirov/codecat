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
    let height: CGFloat
    /// Открыто ли меню под островом. Пока открыто, нижние углы острова
    /// распрямляются: скругляет их уже меню, и две чёрные формы читаются как один
    /// силуэт. Со скруглением на стыке в углах проступали бы обои — тот самый
    /// видимый разрыв.
    var menuIsOpen: Bool = false

    var body: some View {
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
        .background(Color.black)
        // Верхние углы прямые — они упираются в кромку экрана.
        .clipShape(BottomRoundedRectangle(radius: menuIsOpen ? 0 : IslandLayout.cornerRadius))
        // Смена радиуса намеренно без анимации.
        //
        // Углы острова при открытом меню — внутренний шов, который меню
        // закрывает собой с первого же пункта выезда. Любая длительность здесь
        // означает промежуток, когда углы уже скруглены меньше, чем были, а меню
        // ещё не доехало их прикрыть, — и в стыке снова открываются щели с
        // обоями, ровно те же, ради которых всё это затевалось. Мгновенная смена
        // не видна: в первом же кадре кромку закрывает выезжающая форма.
        //
        // Обратно углы возвращаются тоже сразу, и это согласовано с закрытием:
        // меню не уезжает анимацией, а сразу уводится с экрана.
    }

    private var cat: some View {
        MascotView(skin: appState.skin,
                   status: appState.store.aggregate,
                   sessionCount: appState.store.badgeCount,
                   drawingSize: spriteSize,
                   canvasSize: CGSize(width: spriteSize.width, height: height),
                   showsBadge: false,
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

/// Прямоугольник со скруглением только снизу.
///
/// `animatableData` не для красоты: радиус меняется в момент раскрытия меню, и
/// без него углы щёлкали бы мгновенно, пока сама форма едет пружиной.
struct BottomRoundedRectangle: Shape {
    var radius: CGFloat

    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = max(0, min(radius, min(rect.width, rect.height) / 2))
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        if r > 0 {
            path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY),
                              control: CGPoint(x: rect.maxX, y: rect.maxY))
        }
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        if r > 0 {
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r),
                              control: CGPoint(x: rect.minX, y: rect.maxY))
        }
        path.closeSubpath()
        return path
    }
}
