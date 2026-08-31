import CoreGraphics

/// Геометрия «острова» — чёрной плашки, накрывающей физический вырез экрана и
/// заходящей крыльями влево и вправо.
///
/// Всё считается из двух вспомогательных областей, которые macOS сообщает для
/// экрана с вырезом (`NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea`):
/// это участки строки меню слева и справа от выреза. Сам вырез — дырка между
/// ними, и другого способа узнать его ширину система не даёт.
///
/// Здесь нет прямоугольников содержимого (кота, счётчика): `IslandView` кладёт
/// три известные ширины — левое крыло, вырез, правое крыло — обычным `HStack`,
/// и заводить ради этого вторую систему координат незачем.
public enum IslandLayout {

    /// Отступ от спрайта до края крыла с каждой стороны. Крылья физически
    /// перекрывают строку меню (слева меню приложения, справа чужие статус-иконки),
    /// поэтому они делаются ровно по спрайту, а не «пошире на глаз».
    public static let wingPadding: CGFloat = 8

    /// Правое крыло не зависит от облика: там либо число сессий, либо точка.
    public static let counterWingWidth: CGFloat = 34

    /// Скругление нижних углов острова и меню. Верхние углы острова прямые —
    /// они упираются в кромку экрана.
    public static let cornerRadius: CGFloat = 10

    /// Есть ли у экрана вырез. На экране без выреза верхний safe-area-инсет равен
    /// нулю; на встроенном экране MacBook Pro он равен высоте строки меню (32 pt).
    public static func hasNotch(safeAreaTop: CGFloat) -> Bool { safeAreaTop > 0 }

    /// Вырез — промежуток между вспомогательными областями. `nil`, если система их
    /// не сообщила (экран без выреза) или если между ними нет положительной ширины.
    public static func notchRect(auxLeft: CGRect?, auxRight: CGRect?) -> CGRect? {
        guard let auxLeft, let auxRight else { return nil }
        let width = auxRight.minX - auxLeft.maxX
        guard width > 0, auxLeft.height > 0 else { return nil }
        return CGRect(x: auxLeft.maxX, y: auxLeft.minY, width: width, height: auxLeft.height)
    }

    /// Ширина крыла под спрайт: сам спрайт плюс `wingPadding` с каждой стороны.
    public static func wingWidth(spriteWidth: CGFloat) -> CGFloat {
        spriteWidth + 2 * wingPadding
    }

    /// Вся плашка: вырез плюс два крыла. Высота равна высоте выреза — остров не
    /// выходит за строку меню.
    public static func islandFrame(notch: CGRect,
                                   leftWingWidth: CGFloat,
                                   rightWingWidth: CGFloat) -> CGRect {
        CGRect(x: notch.minX - leftWingWidth,
               y: notch.minY,
               width: leftWingWidth + notch.width + rightWingWidth,
               height: notch.height)
    }

    /// Выпадающее меню: верхняя кромка вплотную к низу острова (щель между чёрным
    /// меню и чёрным островом сразу выдала бы, что это два разных окна), центр по
    /// острову, всё подрезано по краям экрана.
    public static func menuFrame(island: CGRect,
                                 size: CGSize,
                                 screenFrame: CGRect,
                                 edgeInset: CGFloat = 8) -> CGRect {
        let lowerBound = screenFrame.minX + edgeInset
        let upperBound = screenFrame.maxX - size.width - edgeInset
        // Меню шире экрана: подрезка сверху и снизу противоречат друг другу,
        // поэтому прижимаем к левому краю, а не считаем min от max.
        let x = upperBound >= lowerBound
            ? min(max(island.midX - size.width / 2, lowerBound), upperBound)
            : lowerBound
        let y = max(screenFrame.minY, island.minY - size.height)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}
