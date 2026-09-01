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

    /// Скругление в местах, где остров упирается в верхнюю кромку экрана —
    /// вогнутое, «наружу».
    ///
    /// Прямой угол на стыке читается как ступенька: чёрная плашка приставлена к
    /// кромке, а не растёт из неё. Вогнутая галтель убирает ступеньку — чёрное
    /// перетекает в кромку экрана без излома, и вырез с островом читаются одной
    /// непрерывной формой. Тот же приём macOS применяет к самому вырезу.
    ///
    /// Плашка ради этого становится шире на `edgeRadius` с каждой стороны: галтель
    /// лежит снаружи корпуса острова, и без запаса ей негде поместиться. Ширина
    /// самого корпуса при этом не меняется — крылья остаются по 72 pt.
    public static let edgeRadius: CGFloat = 10

    /// Скругление нижних углов острова и меню. Верхние углы острова прямые —
    /// они упираются в кромку экрана.
    ///
    /// 16 pt при высоте острова 32 pt — это половина высоты, то есть нижняя
    /// кромка закруглена целиком, без прямого участка между дугами по бокам.
    /// Так плашка читается формой, а не прямоугольником со сглаженными углами;
    /// физический вырез рядом закруглён примерно так же, и меньший радиус рядом
    /// с ним смотрится сухо. Больше половины высоты брать нельзя: фигура зажимает
    /// радиус этим пределом, и разница перестала бы быть видимой.
    public static let cornerRadius: CGFloat = 16

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

    /// Прямоугольник окна острова: корпус плюс место под галтели с обеих сторон.
    /// Отдельно от `islandFrame`, потому что это разные величины: `islandFrame` —
    /// то, по чему раскладывается содержимое (крыло, вырез, крыло), а это — то, что
    /// нужно закрасить.
    public static func silhouetteFrame(island: CGRect) -> CGRect {
        island.insetBy(dx: -edgeRadius, dy: 0)
    }

    /// Контур острова в координатах SwiftUI (ось Y вниз, начало — левый верхний
    /// угол): вогнутые галтели у кромки экрана сверху, скруглённые углы снизу.
    ///
    /// `rect` — весь прямоугольник окна (`silhouetteFrame`), то есть корпус плюс
    /// галтели по краям. `edgeRadius` нулевой (или не влезающий) просто даёт прямые
    /// верхние углы — форма остаётся корректной.
    ///
    /// Дуги строятся кубическими Безье с константой 0.5523: квадратичная кривая для
    /// четверти окружности ошибается примерно на 5%, и на стыке с настоящей дугой
    /// выреза это было бы видно.
    public static func silhouettePath(in rect: CGRect,
                                      bottomRadius: CGFloat,
                                      edgeRadius: CGFloat = IslandLayout.edgeRadius) -> CGPath {
        let k: CGFloat = 0.5523
        // Зажимаем так, чтобы форма не выворачивалась на узком или низком острове:
        // галтель не шире половины ширины и не выше самого острова, а нижний радиус
        // не больше половины оставшегося корпуса и того, что осталось от высоты
        // после галтели. Иначе вертикальная стенка корпуса пошла бы снизу вверх.
        let e = max(0, min(edgeRadius, min(rect.width / 2, rect.height)))
        let bodyWidth = rect.width - 2 * e
        let b = max(0, min(bottomRadius, min(bodyWidth / 2, rect.height - e)))
        let left = rect.minX, right = rect.maxX, top = rect.minY, bottom = rect.maxY
        let bodyLeft = left + e, bodyRight = right - e

        let path = CGMutablePath()
        path.move(to: CGPoint(x: left, y: top))
        path.addLine(to: CGPoint(x: right, y: top))
        // Правая галтель: из кромки экрана вниз, к правому краю корпуса.
        if e > 0 {
            path.addCurve(to: CGPoint(x: bodyRight, y: top + e),
                          control1: CGPoint(x: right, y: top + e * k),
                          control2: CGPoint(x: bodyRight + e * k, y: top + e))
        }
        path.addLine(to: CGPoint(x: bodyRight, y: bottom - b))
        if b > 0 {
            path.addCurve(to: CGPoint(x: bodyRight - b, y: bottom),
                          control1: CGPoint(x: bodyRight, y: bottom - b + b * k),
                          control2: CGPoint(x: bodyRight - b + b * k, y: bottom))
        }
        path.addLine(to: CGPoint(x: bodyLeft + b, y: bottom))
        if b > 0 {
            path.addCurve(to: CGPoint(x: bodyLeft, y: bottom - b),
                          control1: CGPoint(x: bodyLeft + b - b * k, y: bottom),
                          control2: CGPoint(x: bodyLeft, y: bottom - b + b * k))
        }
        path.addLine(to: CGPoint(x: bodyLeft, y: top + e))
        // Левая галтель: от корпуса обратно к кромке экрана.
        if e > 0 {
            path.addCurve(to: CGPoint(x: left, y: top),
                          control1: CGPoint(x: bodyLeft - e * k, y: top + e),
                          control2: CGPoint(x: left, y: top + e * k))
        }
        path.closeSubpath()
        return path
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
