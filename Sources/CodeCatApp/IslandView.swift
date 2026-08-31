import SwiftUI
import CodeCatCore

/// Содержимое острова: кот в левом крыле, счётчик в правом, между ними — дырка
/// под физический вырез.
///
/// Раскладка — `HStack` по трём известным ширинам, без всякой геометрии в самом
/// виде: где эти ширины берутся, знает `IslandController`, а считает их
/// `IslandLayout`.
struct IslandView: View {
    @ObservedObject var appState: AppState
    let notchWidth: CGFloat
    let leftWingWidth: CGFloat
    let rightWingWidth: CGFloat
    let spriteSize: CGSize
    let height: CGFloat

    private var isWaiting: Bool {
        if case .waiting = appState.store.aggregate { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 0) {
            cat
                .frame(width: leftWingWidth, height: height)
            // Физический вырез: сюда ничего не кладём, там дырка в матрице.
            Color.clear
                .frame(width: notchWidth, height: height)
            counter
                .frame(width: rightWingWidth, height: height)
        }
        .frame(height: height)
        .background(Color.black)
        // Верхние углы прямые — они упираются в кромку экрана; скругляются только
        // нижние, чтобы плашка читалась как продолжение выреза.
        .clipShape(BottomRoundedRectangle(radius: IslandLayout.cornerRadius))
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

    @ViewBuilder
    private var counter: some View {
        let count = appState.store.badgeCount
        if count > 0 {
            // Цвет повторяет логику бейджа плавающего кота: ожидание пользователя —
            // единственное состояние, которое имеет право быть красным.
            Text("\(count)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isWaiting ? Color(red: 1.0, green: 0.35, blue: 0.35) : .white)
        } else {
            // Считать нечего — но остров остаётся на месте, иначе на него нельзя
            // будет навести мышь. Точка вместо числа.
            Circle()
                .fill(Color.white.opacity(0.35))
                .frame(width: 6, height: 6)
        }
    }
}

/// Прямоугольник со скруглением только снизу.
struct BottomRoundedRectangle: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
                          control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius),
                          control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
