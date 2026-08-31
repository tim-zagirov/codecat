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

    func testWingIsTheSpritePlusPaddingOnBothSides() {
        XCTAssertEqual(IslandLayout.wingWidth(spriteWidth: 54),
                       54 + 2 * IslandLayout.wingPadding, accuracy: 0.001)
        XCTAssertEqual(IslandLayout.wingWidth(spriteWidth: 32), 48, accuracy: 0.001)
    }

    /// Крылья растут наружу от краёв выреза: сам вырез остаётся ровно там, где был,
    /// и ни одно крыло в него не залезает.
    func testIslandGrowsOutwardWithoutEatingIntoTheNotch() {
        let notch = CGRect(x: 771, y: 1085, width: 185, height: 32)
        let island = IslandLayout.islandFrame(notch: notch, leftWingWidth: 70, rightWingWidth: 34)
        XCTAssertEqual(island, CGRect(x: 701, y: 1085, width: 70 + 185 + 34, height: 32))
        XCTAssertEqual(notch.minX - island.minX, 70, accuracy: 0.001)
        XCTAssertEqual(island.maxX - notch.maxX, 34, accuracy: 0.001)
        XCTAssertEqual(island.height, notch.height, accuracy: 0.001)
    }

    // MARK: - Выпадающее меню

    /// Верхняя кромка меню вплотную к низу острова — между ними не должно быть
    /// щели, иначе чёрное меню перестанет читаться как продолжение выреза.
    func testMenuHangsDirectlyBelowTheIsland() {
        let island = CGRect(x: 701, y: 1085, width: 289, height: 32)
        let menu = IslandLayout.menuFrame(island: island,
                                          size: CGSize(width: 290, height: 200),
                                          screenFrame: screen)
        XCTAssertEqual(menu.maxY, island.minY, accuracy: 0.001)
        XCTAssertEqual(menu.midX, island.midX, accuracy: 0.001)
    }

    /// Остров у самого правого края экрана не имеет права вытолкнуть меню за границу.
    func testMenuIsClampedToTheScreenEdges() {
        let island = CGRect(x: 1650, y: 1085, width: 78, height: 32)
        let menu = IslandLayout.menuFrame(island: island,
                                          size: CGSize(width: 290, height: 200),
                                          screenFrame: screen)
        XCTAssertLessThanOrEqual(menu.maxX, screen.maxX)
        XCTAssertGreaterThanOrEqual(menu.minX, screen.minX)
    }

    /// Узкий экран не выталкивает меню за границу: когда меню шире самого
    /// экрана, `upperBound < lowerBound`, и `menuFrame` обязан прижать меню к
    /// левому краю, а не пытаться зажать его между противоречащими друг другу
    /// границами (см. комментарий у `min(max(...))` в реализации).
    func testMenuWiderThanScreenIsPinnedToTheLeftEdge() {
        let narrowScreen = CGRect(x: 0, y: 0, width: 200, height: 1117)
        let island = CGRect(x: 60, y: 1085, width: 78, height: 32)
        let menu = IslandLayout.menuFrame(island: island,
                                          size: CGSize(width: 290, height: 200),
                                          screenFrame: narrowScreen)
        XCTAssertEqual(menu.minX, 8, accuracy: 0.001)
    }

    // MARK: - Числа из спеки

    /// Правое крыло — число из спеки; в остальных тестах оно фигурирует только
    /// как литерал, здесь закреплено явно.
    func testCounterWingWidthMatchesSpec() {
        XCTAssertEqual(IslandLayout.counterWingWidth, 34)
    }

    /// Меню выше экрана не должно уезжать под нижнюю границу.
    func testMenuNeverGoesBelowTheScreen() {
        let island = CGRect(x: 701, y: 1085, width: 289, height: 32)
        let menu = IslandLayout.menuFrame(island: island,
                                          size: CGSize(width: 290, height: 4000),
                                          screenFrame: screen)
        XCTAssertGreaterThanOrEqual(menu.minY, screen.minY)
    }
}
