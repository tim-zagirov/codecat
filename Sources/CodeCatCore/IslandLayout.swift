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
    /// вогнутое, внутрь корпуса.
    ///
    /// Прямой угол на стыке читается как ступенька: чёрная плашка приставлена к
    /// кромке, а не растёт из неё. Галтель убирает ступеньку — стенка корпуса
    /// плавно заворачивает в кромку экрана, а угол обоев рядом получает скругление.
    /// Дуга касается кромки сверху и стенки корпуса сбоку; если перепутать
    /// касательные, она выгнется наружу и у острова вырастут плечи.
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
        // Правая галтель: дуга касается кромки экрана сверху и стенки корпуса сбоку.
        // Касательные именно так, а не наоборот: при обратной паре контрольных точек
        // дуга выгибается наружу, и вместо перетекания в кромку у острова вырастают
        // плечи — проверено отрисовкой, выглядит как уши.
        if e > 0 {
            path.addCurve(to: CGPoint(x: bodyRight, y: top + e),
                          control1: CGPoint(x: right - e * k, y: top),
                          control2: CGPoint(x: bodyRight, y: top + e - e * k))
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
        // Левая галтель, зеркально правой.
        if e > 0 {
            path.addCurve(to: CGPoint(x: left, y: top),
                          control1: CGPoint(x: bodyLeft, y: top + e - e * k),
                          control2: CGPoint(x: left + e * k, y: top))
        }
        path.closeSubpath()
        return path
    }

    /// Рамка окна острова при полной высоте `totalHeight` (полоса острова плюс
    /// раскрытое меню).
    ///
    /// Верхняя кромка не двигается никогда: окно растёт вниз от кромки экрана.
    /// Ширина — всегда ширина силуэта, потому что остров и меню теперь одна форма в
    /// одном окне; отдельной ширины у меню больше нет, а значит нет и уступа на
    /// стыке, который раньше приходилось прятать.
    ///
    /// Высота зажата снизу полосой острова (меньше неё окно быть не может) и сверху
    /// нижним краем экрана.
    public static func windowFrame(island: CGRect,
                                   totalHeight: CGFloat,
                                   screenFrame: CGRect) -> CGRect {
        let silhouette = silhouetteFrame(island: island)
        let available = island.maxY - screenFrame.minY
        let height = max(island.height, min(totalHeight, available))
        return CGRect(x: silhouette.minX, y: island.maxY - height,
                      width: silhouette.width, height: height)
    }
}
