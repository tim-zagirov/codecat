import XCTest
@testable import CodeCatCore

final class MascotDisplayModeTests: XCTestCase {

    /// rawValue уходит в UserDefaults, поэтому менять эти строки нельзя — иначе
    /// у пользователя молча слетит выбранный режим.
    func testRawValuesAreStable() {
        XCTAssertEqual(MascotDisplayMode.floating.rawValue, "floating")
        XCTAssertEqual(MascotDisplayMode.island.rawValue, "island")
    }

    /// По умолчанию — то, что было всегда: плавающий кот. Установка обновлённого
    /// приложения не имеет права сама сменить пользователю вид.
    func testDefaultIsTheFloatingMascot() {
        XCTAssertEqual(MascotDisplayMode.default, .floating)
    }

    /// Мусор и отсутствие значения в настройках приводят к режиму по умолчанию,
    /// а не к падению.
    func testUnknownIdentifiersFallBackToTheDefault() {
        XCTAssertEqual(MascotDisplayMode.mode(withID: nil), .floating)
        XCTAssertEqual(MascotDisplayMode.mode(withID: ""), .floating)
        XCTAssertEqual(MascotDisplayMode.mode(withID: "notch"), .floating)
        XCTAssertEqual(MascotDisplayMode.mode(withID: "island"), .island)
    }

    func testEveryModeHasARussianTitle() {
        XCTAssertEqual(MascotDisplayMode.allCases.count, 2)
        for mode in MascotDisplayMode.allCases {
            XCTAssertFalse(mode.title.isEmpty, mode.rawValue)
        }
    }
}
