import XCTest
@testable import CodeCatCore

/// A movement's chronology: what to show N seconds after a state is entered.
final class SpriteTimelineTests: XCTestCase {

    private func frame(_ index: Int) -> SpriteFrame { SpriteFrame(sheet: "s.png", index: index) }

    private func phase(_ indices: [Int], fps: Double, repeats: Int? = nil) -> SpritePhase {
        SpritePhase(frames: indices.map(frame), framesPerSecond: fps, repeats: repeats)
    }

    /// An ordinary single-phase loop behaves as before — it runs forever.
    func testASingleEndlessPhaseLoopsForever() {
        let animation = SpriteAnimation(frames: [frame(0), frame(1), frame(2)], framesPerSecond: 1)
        XCTAssertEqual(SpriteTimeline.frame(at: 0, in: animation), frame(0))
        XCTAssertEqual(SpriteTimeline.frame(at: 1.5, in: animation), frame(1))
        XCTAssertEqual(SpriteTimeline.frame(at: 3, in: animation), frame(0), "round two")
        XCTAssertEqual(SpriteTimeline.frame(at: 3001, in: animation), frame(1), "and an hour later too")
    }

    /// What was asked for: the action plays a given number of times, and then the cat
    /// lies down and stays there.
    func testAnIntroPlaysItsRepeatsAndThenGivesWayToRest() {
        // 2 frames at 1 fps = 2 seconds per pass, two passes = 4 seconds.
        let animation = SpriteAnimation(phases: [
            phase([0, 1], fps: 1, repeats: 2),
            phase([8, 9], fps: 1),
        ])
        XCTAssertEqual(SpriteTimeline.frame(at: 0, in: animation), frame(0))
        XCTAssertEqual(SpriteTimeline.frame(at: 1, in: animation), frame(1))
        XCTAssertEqual(SpriteTimeline.frame(at: 2, in: animation), frame(0), "second pass")
        XCTAssertEqual(SpriteTimeline.frame(at: 3.9, in: animation), frame(1))
        XCTAssertEqual(SpriteTimeline.frame(at: 4, in: animation), frame(8), "the action is done — rest")
        XCTAssertEqual(SpriteTimeline.frame(at: 5, in: animation), frame(9))
        XCTAssertEqual(SpriteTimeline.frame(at: 600, in: animation), frame(8), "and it stays at rest")
    }

    /// Three phases — exactly the "stretched, lay down, sleeping" shape.
    func testThreePhasesRunInOrder() {
        let animation = SpriteAnimation(phases: [
            phase([0], fps: 1, repeats: 2),   // 2 s
            phase([1], fps: 1, repeats: 1),   // 1 s
            phase([2, 3], fps: 1),
        ])
        XCTAssertEqual(SpriteTimeline.frame(at: 0, in: animation), frame(0))
        XCTAssertEqual(SpriteTimeline.frame(at: 1.9, in: animation), frame(0))
        XCTAssertEqual(SpriteTimeline.frame(at: 2, in: animation), frame(1), "transition")
        XCTAssertEqual(SpriteTimeline.frame(at: 2.9, in: animation), frame(1))
        XCTAssertEqual(SpriteTimeline.frame(at: 3, in: animation), frame(2), "rest")
    }

    /// Phases run at different speeds — a phase's duration is measured at its own rate.
    func testPhaseDurationUsesItsOwnFrameRate() {
        let animation = SpriteAnimation(phases: [
            phase([0, 1, 2, 3], fps: 8, repeats: 1),  // 0.5 s
            phase([9], fps: 1),
        ])
        XCTAssertEqual(SpriteTimeline.frame(at: 0.4, in: animation), frame(3))
        XCTAssertEqual(SpriteTimeline.frame(at: 0.5, in: animation), frame(9))
    }

    /// The clock was set back — show the beginning, not the middle of a transition.
    func testNegativeElapsedShowsTheVeryFirstFrame() {
        let animation = SpriteAnimation(phases: [phase([0, 1], fps: 1, repeats: 1), phase([5], fps: 1)])
        XCTAssertEqual(SpriteTimeline.frame(at: -3600, in: animation), frame(0))
    }

    /// Every phase is finite (the registry must never be like that — `MascotSkinsTests`
    /// checks it — but the function has to stay total): hold on the last frame rather
    /// than start over.
    func testAllFinitePhasesHoldTheLastFrame() {
        let animation = SpriteAnimation(phases: [phase([0, 1], fps: 1, repeats: 1)])
        XCTAssertEqual(SpriteTimeline.frame(at: 100, in: animation), frame(1))
    }

    func testEmptyAnimationHasNoFrame() {
        XCTAssertNil(SpriteTimeline.frame(at: 5, in: SpriteAnimation(phases: [])))
        XCTAssertNil(SpriteTimeline.frame(at: 5, in: SpriteAnimation(frames: [], framesPerSecond: 4)))
    }

    /// An empty or stopped phase is skipped rather than eating the whole movement.
    func testAPhaseWithNoFramesOrNoSpeedIsSkipped() {
        let animation = SpriteAnimation(phases: [
            SpritePhase(frames: [], framesPerSecond: 4, repeats: 1),
            SpritePhase(frames: [frame(7)], framesPerSecond: 0, repeats: 1),
            phase([3], fps: 1),
        ])
        XCTAssertEqual(SpriteTimeline.frame(at: 0, in: animation), frame(3))
    }

    /// A real shipped skin, second by second: "Plush" sits down after work is over,
    /// lies down and stays there — in the same pose it sleeps in.
    func testTheShippedDoneAnimationSitsThenLiesDownThenRests() throws {
        let skin = MascotSkins.skin(withID: "mxmaze-kitty")
        let done = try XCTUnwrap(skin.animation(for: .done))
        let sleeping = try XCTUnwrap(skin.animation(for: .sleeping))
        let start = try XCTUnwrap(SpriteTimeline.frame(at: 0, in: done))
        XCTAssertEqual(start, done.phases[0].frames[0], "it begins with the action")
        let atRest = try XCTUnwrap(SpriteTimeline.frame(at: 60, in: done))
        XCTAssertTrue(sleeping.frames.contains(atRest), "a minute later the cat lies as if asleep")
    }
}
