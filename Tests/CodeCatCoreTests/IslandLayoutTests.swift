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

    // MARK: - Выпадающее меню

    /// Верхняя кромка меню вплотную к низу острова — между ними не должно быть
    /// щели, иначе чёрное меню перестанет читаться как продолжение выреза.
    func testMenuHangsDirectlyBelowTheIsland() {
        let island = CGRect(x: 701, y: 1085, width: 329, height: 32)
        let menu = IslandLayout.menuFrame(island: island, height: 200, screenFrame: screen)
        XCTAssertEqual(menu.maxY, island.minY, accuracy: 0.001)
        XCTAssertEqual(menu.midX, island.midX, accuracy: 0.001)
    }

    /// Меню обязано быть ровно той же ширины, что остров: разная ширина двух чёрных
    /// форм — это и есть тот видимый разрыв на стыке, ради которого ширина меню
    /// больше не принимается снаружи, а выводится из острова.
    func testMenuIsExactlyAsWideAsTheIsland() {
        for width in [281.0, 329.0, 400.0] as [CGFloat] {
            let island = CGRect(x: 701, y: 1085, width: width, height: 32)
            let menu = IslandLayout.menuFrame(island: island, height: 200, screenFrame: screen)
            XCTAssertEqual(menu.width, island.width, accuracy: 0.001, "ширина \(width)")
        }
    }

    /// Остров у самого правого края экрана не имеет права вытолкнуть меню за границу.
    func testMenuIsClampedToTheScreenEdges() {
        let island = CGRect(x: 1650, y: 1085, width: 78, height: 32)
        let menu = IslandLayout.menuFrame(island: island, height: 200, screenFrame: screen)
        XCTAssertLessThanOrEqual(menu.maxX, screen.maxX)
        XCTAssertGreaterThanOrEqual(menu.minX, screen.minX)
    }

    /// Узкий экран не выталкивает меню за границу: когда меню шире самого
    /// экрана, `upperBound < lowerBound`, и `menuFrame` обязан прижать меню к
    /// левому краю, а не пытаться зажать его между противоречащими друг другу
    /// границами (см. комментарий у `min(max(...))` в реализации).
    func testMenuWiderThanScreenIsPinnedToTheLeftEdge() {
        let narrowScreen = CGRect(x: 0, y: 0, width: 200, height: 1117)
        let island = CGRect(x: 60, y: 1085, width: 290, height: 32)
        let menu = IslandLayout.menuFrame(island: island, height: 200, screenFrame: narrowScreen)
        XCTAssertEqual(menu.minX, 8, accuracy: 0.001)
    }

    // MARK: - Числа из спеки

    /// Ширина крыла — число из визуальной спецификации; в остальных тестах она
    /// фигурирует только как производная, здесь закреплена явно.
    func testWingWidthMatchesSpec() {
        XCTAssertEqual(IslandLayout.wingWidth, 72)
    }

    /// Меню выше экрана не должно уезжать под нижнюю границу.
    func testMenuNeverGoesBelowTheScreen() {
        let island = CGRect(x: 701, y: 1085, width: 329, height: 32)
        let menu = IslandLayout.menuFrame(island: island, height: 4000, screenFrame: screen)
        XCTAssertGreaterThanOrEqual(menu.minY, screen.minY)
    }
}
