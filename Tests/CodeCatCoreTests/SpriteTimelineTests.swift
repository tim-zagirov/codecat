import XCTest
@testable import CodeCatCore

/// Хронология движения: что показывать через N секунд после входа в состояние.
final class SpriteTimelineTests: XCTestCase {

    private func frame(_ index: Int) -> SpriteFrame { SpriteFrame(sheet: "s.png", index: index) }

    private func phase(_ indices: [Int], fps: Double, repeats: Int? = nil) -> SpritePhase {
        SpritePhase(frames: indices.map(frame), framesPerSecond: fps, repeats: repeats)
    }

    /// Обычная петля из одной фазы ведёт себя как раньше — крутится вечно.
    func testASingleEndlessPhaseLoopsForever() {
        let animation = SpriteAnimation(frames: [frame(0), frame(1), frame(2)], framesPerSecond: 1)
        XCTAssertEqual(SpriteTimeline.frame(at: 0, in: animation), frame(0))
        XCTAssertEqual(SpriteTimeline.frame(at: 1.5, in: animation), frame(1))
        XCTAssertEqual(SpriteTimeline.frame(at: 3, in: animation), frame(0), "пошла по второму кругу")
        XCTAssertEqual(SpriteTimeline.frame(at: 3001, in: animation), frame(1), "и через час тоже")
    }

    /// То, о чём просили: действие проигрывается заданное число раз, а потом кот
    /// укладывается и остаётся лежать.
    func testAnIntroPlaysItsRepeatsAndThenGivesWayToRest() {
        // 2 кадра при 1 fps = 2 секунды за проход, два прохода = 4 секунды.
        let animation = SpriteAnimation(phases: [
            phase([0, 1], fps: 1, repeats: 2),
            phase([8, 9], fps: 1),
        ])
        XCTAssertEqual(SpriteTimeline.frame(at: 0, in: animation), frame(0))
        XCTAssertEqual(SpriteTimeline.frame(at: 1, in: animation), frame(1))
        XCTAssertEqual(SpriteTimeline.frame(at: 2, in: animation), frame(0), "второй проход")
        XCTAssertEqual(SpriteTimeline.frame(at: 3.9, in: animation), frame(1))
        XCTAssertEqual(SpriteTimeline.frame(at: 4, in: animation), frame(8), "действие отыграно — покой")
        XCTAssertEqual(SpriteTimeline.frame(at: 5, in: animation), frame(9))
        XCTAssertEqual(SpriteTimeline.frame(at: 600, in: animation), frame(8), "и остаётся в покое")
    }

    /// Три фазы — ровно форма «потянулся, улёгся, спит».
    func testThreePhasesRunInOrder() {
        let animation = SpriteAnimation(phases: [
            phase([0], fps: 1, repeats: 2),   // 2 с
            phase([1], fps: 1, repeats: 1),   // 1 с
            phase([2, 3], fps: 1),
        ])
        XCTAssertEqual(SpriteTimeline.frame(at: 0, in: animation), frame(0))
        XCTAssertEqual(SpriteTimeline.frame(at: 1.9, in: animation), frame(0))
        XCTAssertEqual(SpriteTimeline.frame(at: 2, in: animation), frame(1), "переход")
        XCTAssertEqual(SpriteTimeline.frame(at: 2.9, in: animation), frame(1))
        XCTAssertEqual(SpriteTimeline.frame(at: 3, in: animation), frame(2), "покой")
    }

    /// Фазы бывают разной скорости — длительность считается по своей.
    func testPhaseDurationUsesItsOwnFrameRate() {
        let animation = SpriteAnimation(phases: [
            phase([0, 1, 2, 3], fps: 8, repeats: 1),  // 0.5 с
            phase([9], fps: 1),
        ])
        XCTAssertEqual(SpriteTimeline.frame(at: 0.4, in: animation), frame(3))
        XCTAssertEqual(SpriteTimeline.frame(at: 0.5, in: animation), frame(9))
    }

    /// Часы перевели назад — показываем начало, а не середину перехода.
    func testNegativeElapsedShowsTheVeryFirstFrame() {
        let animation = SpriteAnimation(phases: [phase([0, 1], fps: 1, repeats: 1), phase([5], fps: 1)])
        XCTAssertEqual(SpriteTimeline.frame(at: -3600, in: animation), frame(0))
    }

    /// Все фазы конечны (в реестре так быть не должно — это проверяет
    /// `MascotSkinsTests`, — но функция обязана оставаться тотальной): замираем на
    /// последнем кадре, а не начинаем сначала.
    func testAllFinitePhasesHoldTheLastFrame() {
        let animation = SpriteAnimation(phases: [phase([0, 1], fps: 1, repeats: 1)])
        XCTAssertEqual(SpriteTimeline.frame(at: 100, in: animation), frame(1))
    }

    func testEmptyAnimationHasNoFrame() {
        XCTAssertNil(SpriteTimeline.frame(at: 5, in: SpriteAnimation(phases: [])))
        XCTAssertNil(SpriteTimeline.frame(at: 5, in: SpriteAnimation(frames: [], framesPerSecond: 4)))
    }

    /// Пустая или остановленная фаза пропускается, а не съедает движение целиком.
    func testAPhaseWithNoFramesOrNoSpeedIsSkipped() {
        let animation = SpriteAnimation(phases: [
            SpritePhase(frames: [], framesPerSecond: 4, repeats: 1),
            SpritePhase(frames: [frame(7)], framesPerSecond: 0, repeats: 1),
            phase([3], fps: 1),
        ])
        XCTAssertEqual(SpriteTimeline.frame(at: 0, in: animation), frame(3))
    }

    /// Настоящий облик пользователя, по секундам: «Плюшевый» после конца работы
    /// садится, укладывается и остаётся лежать — той же позой, что и во сне.
    func testTheShippedDoneAnimationSitsThenLiesDownThenRests() throws {
        let skin = MascotSkins.skin(withID: "mxmaze-kitty")
        let done = try XCTUnwrap(skin.animation(for: .done))
        let sleeping = try XCTUnwrap(skin.animation(for: .sleeping))
        let start = try XCTUnwrap(SpriteTimeline.frame(at: 0, in: done))
        XCTAssertEqual(start, done.phases[0].frames[0], "начинается с действия")
        let atRest = try XCTUnwrap(SpriteTimeline.frame(at: 60, in: done))
        XCTAssertTrue(sleeping.frames.contains(atRest), "через минуту кот лежит, как во сне")
    }
}
