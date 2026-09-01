import XCTest
import CoreGraphics
@testable import CodeCatCore

/// Все числа здесь — замеры с целевой машины (MacBook Pro 16"), а не круглые
/// величины «на глаз»: экран 1728x1117 pt, строка меню 32 pt, вырез 185 pt
/// шириной в x ∈ [771, 956]. См. раздел «Что измерено до проектирования» в спеке.
final class IslandLayoutTests: XCTestCase {

    private let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    private let auxLeft = CGRect(x: 0, y: 1085, width: 771, height: 32)
    private let auxRight = CGRect(x: 956, y: 1085, width: 772, height: 32)

    // MARK: - Вырез

    func testNotchIsTheGapBetweenTheTwoAuxiliaryAreas() {
        let notch = IslandLayout.notchRect(auxLeft: auxLeft, auxRight: auxRight)
        XCTAssertEqual(notch, CGRect(x: 771, y: 1085, width: 185, height: 32))
    }

    /// Экран без выреза не сообщает вспомогательных областей вовсе.
    func testNoNotchWhenAuxiliaryAreasAreMissing() {
        XCTAssertNil(IslandLayout.notchRect(auxLeft: nil, auxRight: nil))
        XCTAssertNil(IslandLayout.notchRect(auxLeft: auxLeft, auxRight: nil))
        XCTAssertNil(IslandLayout.notchRect(auxLeft: nil, auxRight: auxRight))
    }

    /// Области сомкнулись или перекрылись — дырки между ними нет, значит острову
    /// не за что зацепиться. Ноль ширины тоже не вырез.
    func testNoNotchWhenAreasTouchOrOverlap() {
        let touching = CGRect(x: 771, y: 1085, width: 957, height: 32)
        XCTAssertNil(IslandLayout.notchRect(auxLeft: auxLeft, auxRight: touching))
        let overlapping = CGRect(x: 700, y: 1085, width: 1028, height: 32)
        XCTAssertNil(IslandLayout.notchRect(auxLeft: auxLeft, auxRight: overlapping))
    }

    func testHasNotchFollowsTheSafeAreaInset() {
        XCTAssertTrue(IslandLayout.hasNotch(safeAreaTop: 32))
        XCTAssertFalse(IslandLayout.hasNotch(safeAreaTop: 0))
    }

    // MARK: - Крылья

    /// Главное требование композиции: чёрное пятно обязано стоять ровно по центру
    /// выреза. Кот — объект с габаритом, счётчик — штрих, и уравнять их можно
    /// только геометрией, поэтому крылья одинаковы с обеих сторон независимо от
    /// того, насколько широк спрайт текущего облика.
    func testWingsAreSymmetricAroundTheNotch() {
        let notch = CGRect(x: 771, y: 1085, width: 185, height: 32)
        let island = IslandLayout.islandFrame(notch: notch)
        XCTAssertEqual(notch.minX - island.minX, island.maxX - notch.maxX, accuracy: 0.001)
        XCTAssertEqual(island.midX, notch.midX, accuracy: 0.001)
    }

    /// Крылья растут наружу от краёв выреза: сам вырез остаётся ровно там, где был,
    /// и ни одно крыло в него не залезает.
    func testIslandGrowsOutwardWithoutEatingIntoTheNotch() {
        let notch = CGRect(x: 771, y: 1085, width: 185, height: 32)
        let island = IslandLayout.islandFrame(notch: notch)
        let wing = IslandLayout.wingWidth
        XCTAssertEqual(island, CGRect(x: 771 - wing, y: 1085, width: 2 * wing + 185, height: 32))
        XCTAssertEqual(island.height, notch.height, accuracy: 0.001)
    }

    /// Крыло рассчитано на самый широкий облик — LuizMelo `cat-4`, 28×16 px, что при
    /// обязательном целочисленном ×2 даёт 56 pt, — и оставляет отступ с обеих сторон.
    /// Уже нельзя: кот упрётся в кромку плашки.
    func testWingFitsTheWidestSkinWithPaddingOnBothSides() {
        XCTAssertGreaterThanOrEqual(IslandLayout.wingWidth, 56 + 2 * IslandLayout.wingPadding)
    }

    // MARK: - Окно: остров и меню — одна форма

    /// Верхняя кромка окна не двигается: форма растёт вниз от кромки экрана, а не
    /// переезжает. Это и есть «выезжает из острова».
    func testWindowGrowsDownwardsAndKeepsItsTopEdgeAtTheScreenEdge() {
        let island = CGRect(x: 701, y: 1085, width: 329, height: 32)
        for total in [32.0, 120.0, 400.0] as [CGFloat] {
            let frame = IslandLayout.windowFrame(island: island, totalHeight: total,
                                                 screenFrame: screen)
            XCTAssertEqual(frame.maxY, island.maxY, accuracy: 0.001, "высота \(total)")
            XCTAssertEqual(frame.height, total, accuracy: 0.001, "высота \(total)")
        }
    }

    /// Ширина окна всегда одна — ширина силуэта. Отдельной ширины у меню больше нет,
    /// а значит нет и уступа на стыке, который раньше приходилось прятать.
    func testWindowIsAlwaysAsWideAsTheSilhouette() {
        for width in [281.0, 329.0, 400.0] as [CGFloat] {
            let island = CGRect(x: 701, y: 1085, width: width, height: 32)
            let frame = IslandLayout.windowFrame(island: island, totalHeight: 200,
                                                 screenFrame: screen)
            XCTAssertEqual(frame.width, IslandLayout.silhouetteFrame(island: island).width,
                           accuracy: 0.001, "ширина \(width)")
            XCTAssertEqual(frame.midX, island.midX, accuracy: 0.001)
        }
    }

    /// Ниже полосы острова окно не сжимается: это его собственная высота в покое.
    func testWindowNeverShrinksBelowTheIslandStrip() {
        let island = CGRect(x: 701, y: 1085, width: 329, height: 32)
        let frame = IslandLayout.windowFrame(island: island, totalHeight: 0, screenFrame: screen)
        XCTAssertEqual(frame.height, island.height, accuracy: 0.001)
    }

    /// Меню выше экрана не должно уезжать под нижнюю границу.
    func testWindowNeverGoesBelowTheScreen() {
        let island = CGRect(x: 701, y: 1085, width: 329, height: 32)
        let frame = IslandLayout.windowFrame(island: island, totalHeight: 4000,
                                             screenFrame: screen)
        XCTAssertGreaterThanOrEqual(frame.minY, screen.minY)
    }

    // MARK: - Числа из спеки

    /// Ширина крыла — число из визуальной спецификации; в остальных тестах она
    /// фигурирует только как производная, здесь закреплена явно.
    func testWingWidthMatchesSpec() {
        XCTAssertEqual(IslandLayout.wingWidth, 72)
    }

    // MARK: - Силуэт: галтели у кромки экрана

    /// Галтели лежат снаружи корпуса, поэтому окно шире — но ровно на них, и центр
    /// не уезжает: остров обязан оставаться симметричным относительно выреза.
    func testSilhouetteFrameAddsTheFilletMarginsOnBothSidesWithoutMovingTheCentre() {
        let island = CGRect(x: 100, y: 1085, width: 329, height: 32)
        let silhouette = IslandLayout.silhouetteFrame(island: island)
        XCTAssertEqual(silhouette.width, island.width + 2 * IslandLayout.edgeRadius)
        XCTAssertEqual(silhouette.height, island.height)
        XCTAssertEqual(silhouette.midX, island.midX)
        XCTAssertEqual(silhouette.minY, island.minY)
    }

    /// Форма касается всех четырёх сторон своего прямоугольника: сверху она во всю
    /// ширину (упирается в кромку экрана), снизу — по корпусу.
    func testSilhouetteFillsTheWholeWidthAtTheScreenEdge() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 32)
        let path = IslandLayout.silhouettePath(in: rect, bottomRadius: 16)
        XCTAssertEqual(path.boundingBox.minX, rect.minX, accuracy: 0.01)
        XCTAssertEqual(path.boundingBox.maxX, rect.maxX, accuracy: 0.01)
        XCTAssertEqual(path.boundingBox.minY, rect.minY, accuracy: 0.01)
        XCTAssertEqual(path.boundingBox.maxY, rect.maxY, accuracy: 0.01)
    }

    /// Суть галтели — куда она загибается. Правильная вогнута внутрь: у самой
    /// стенки корпуса чёрное расширяется наружу, а внешний угол у кромки остаётся
    /// за обоями. Если перепутать касательные, дуга выгибается наружу и закрашивает
    /// именно внешний угол — это и есть «уши», которые так делать не надо.
    func testTheFilletCurvesInwardAndLeavesTheOuterCornerToTheWallpaper() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 32)
        let e = IslandLayout.edgeRadius
        let path = IslandLayout.silhouettePath(in: rect, bottomRadius: 16)

        XCTAssertFalse(path.contains(CGPoint(x: 0.5, y: 0.5)),
                       "внешний угол слева — обои, а не плечо острова")
        XCTAssertFalse(path.contains(CGPoint(x: rect.maxX - 0.5, y: 0.5)),
                       "и справа тоже")
        XCTAssertTrue(path.contains(CGPoint(x: e - 1, y: 1)),
                      "у стенки корпуса галтель закрашена — чёрное вытекает из кромки")
        XCTAssertTrue(path.contains(CGPoint(x: rect.maxX - e + 1, y: 1)))
        XCTAssertTrue(path.contains(CGPoint(x: rect.midX, y: e)), "корпус на месте")
    }

    /// Галтель закрашивает площадь **снаружи** корпуса: точка чуть левее корпуса, у
    /// самой кромки, с галтелью чёрная, а без неё — обои. Так видно, что расширение
    /// даёт именно галтель, а не что-то ещё.
    func testTheFilletFillsSpaceOutsideTheBodyThatIsOtherwiseWallpaper() {
        let body = CGRect(x: 0, y: 0, width: 200, height: 32)
        let spot = CGPoint(x: body.minX - 1, y: body.minY + 1)
        let withFillet = IslandLayout.silhouettePath(
            in: IslandLayout.silhouetteFrame(island: body), bottomRadius: 16)
        let square = IslandLayout.silhouettePath(in: body, bottomRadius: 16, edgeRadius: 0)
        XCTAssertTrue(withFillet.contains(spot))
        XCTAssertFalse(square.contains(spot))
    }

    /// Нулевой радиус галтели — прежняя форма с прямыми верхними углами. Нужен и
    /// как деградация на узком острове, и чтобы разница была проверяема.
    func testZeroEdgeRadiusLeavesSquareTopCorners() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 32)
        let path = IslandLayout.silhouettePath(in: rect, bottomRadius: 16, edgeRadius: 0)
        XCTAssertTrue(path.contains(CGPoint(x: 0.5, y: 10)), "угол прямой — закрашено")
    }

    /// Радиусы, не влезающие в прямоугольник, зажимаются, а не выворачивают форму
    /// наизнанку: остров бывает узким на маленьком вырезе.
    func testOversizedRadiiAreClampedAndTheShapeStaysInsideItsRect() {
        let rect = CGRect(x: 0, y: 0, width: 20, height: 8)
        let path = IslandLayout.silhouettePath(in: rect, bottomRadius: 999, edgeRadius: 999)
        XCTAssertTrue(rect.insetBy(dx: -0.01, dy: -0.01).contains(path.boundingBox))
        XCTAssertFalse(path.isEmpty)
    }
}
