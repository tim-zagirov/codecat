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

    /// Ширина крыла, одна и та же слева и справа.
    ///
    /// Крылья намеренно не подгоняются под текущий облик. Кот — объект с
    /// габаритом, счётчик — штрих, и уравновесить их можно только геометрией:
    /// равные крылья ставят всё чёрное пятно ровно по центру выреза при любом
    /// облике. Раньше крыло считалось по спрайту (48–72 pt слева против
    /// фиксированных 34 справа), и пятно уезжало от центра экрана на 9.5 pt.
    ///
    /// 72 = 56 (самый широкий спрайт: LuizMelo `cat-4`, 28×16 px при
    /// обязательном целочисленном ×2) плюс отступ с обеих сторон. Облики поуже
    /// просто получают больше воздуха вокруг кота; ширина острова при смене
    /// облика не меняется, и в строке меню ничего не дёргается.
    public static let wingWidth: CGFloat = 72

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

    /// Вся плашка: вырез плюс два одинаковых крыла. Высота равна высоте выреза —
    /// остров не выходит за строку меню.
    public static func islandFrame(notch: CGRect) -> CGRect {
        CGRect(x: notch.minX - wingWidth,
               y: notch.minY,
               width: 2 * wingWidth + notch.width,
               height: notch.height)
    }

    /// Выпадающее меню: верхняя кромка вплотную к низу острова (щель между чёрным
    /// меню и чёрным островом сразу выдала бы, что это два разных окна), центр по
    /// острову, всё подрезано по краям экрана.
    /// Ширину меню задаёт остров, а не вызывающий: две чёрные формы разной ширины
    /// на стыке дают видимый разрыв — обои проступают в уступах по краям. Пока
    /// ширина принималась снаружи, разрыв можно было вернуть одним неверным
    /// аргументом; теперь равенство ширин обеспечено по построению.
    public static func menuFrame(island: CGRect,
                                 height: CGFloat,
                                 screenFrame: CGRect,
                                 edgeInset: CGFloat = 8) -> CGRect {
        let width = island.width
        let lowerBound = screenFrame.minX + edgeInset
        let upperBound = screenFrame.maxX - width - edgeInset
        // Меню шире экрана: подрезка слева и справа противоречат друг другу,
        // поэтому прижимаем к левому краю, а не считаем min от max.
        let x = upperBound >= lowerBound
            ? min(max(island.midX - width / 2, lowerBound), upperBound)
            : lowerBound
        let y = max(screenFrame.minY, island.minY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
