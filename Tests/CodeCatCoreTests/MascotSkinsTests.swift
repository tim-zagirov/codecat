import XCTest
@testable import CodeCatCore

final class MascotSkinsTests: XCTestCase {

    /// The key is a *flat* projection of the aggregate status: the animation depends
    /// on the kind of state, never on how many sessions are in it. Covering
    /// `.working`/`.waiting` with several counts is what keeps a future
    /// "count-sensitive" mapping from sneaking in unnoticed.
    func testStatusKeyIgnoresSessionCount() {
        XCTAssertEqual(AggregateStatusKey(.sleeping), .sleeping)
        XCTAssertEqual(AggregateStatusKey(.done), .done)
        XCTAssertEqual(AggregateStatusKey(.problem), .problem)
        for n in [0, 1, 2, 17, 999] {
            XCTAssertEqual(AggregateStatusKey(.working(n)), .working)
            XCTAssertEqual(AggregateStatusKey(.waiting(n)), .waiting)
        }
    }

    func testOnlyCCBYRequiresAttribution() {
        XCTAssertTrue(SkinLicense.ccBy4.requiresAttribution)
        XCTAssertFalse(SkinLicense.cc0.requiresAttribution)
        XCTAssertFalse(SkinLicense.authorTerms(summary: "условия автора").requiresAttribution)
    }

    func testAnimationLookupReturnsNilForAMissingState() {
        let skin = MascotSkin(
            id: "test", name: "Тестовый", author: "никто", license: .cc0,
            sourceURL: "https://example.com", directory: "test", frameSize: 16,
            animations: [.sleeping: SpriteAnimation(
                frames: [SpriteFrame(sheet: "a.png", index: 0)], framesPerSecond: 1)])
        XCTAssertEqual(skin.animation(for: .sleeping)?.frames.count, 1)
        XCTAssertNil(skin.animation(for: .working))
    }
}

extension MascotSkinsTests {

    /// These ids are persisted in `UserDefaults`. Renaming one silently resets the
    /// user's choice back to the default skin, which is why the list is frozen here.
    func testSkinIDsAreExactlyThisFrozenList() {
        XCTAssertEqual(MascotSkins.all.map(\.id), [
            "luizmelo-cat-1", "luizmelo-cat-2", "luizmelo-cat-3",
            "luizmelo-cat-4", "luizmelo-cat-5", "luizmelo-cat-6",
            "elthen-cat", "mxmaze-kitty",
        ])
    }

    func testEveryStateResolvesForEverySpriteSkin() {
        for skin in MascotSkins.all {
            for key in AggregateStatusKey.allCases {
                XCTAssertNotNil(skin.animation(for: key),
                                "\(skin.id) не знает состояния \(key.rawValue)")
            }
        }
    }

    /// Проверяется каждая фаза, а не только первая: у движений с переходом
    /// («потянулся — улёгся — спит») пустая или слишком быстрая фаза в середине
    /// осталась бы незамеченной ровно там, где её никто не разглядывает глазами.
    func testNoAnimationPhaseIsEmptyOrHasFPSOutsideTheAllowedRange() {
        for skin in MascotSkins.all {
            for (key, animation) in skin.animations {
                XCTAssertFalse(animation.phases.isEmpty, "\(skin.id)/\(key.rawValue)")
                for (index, phase) in animation.phases.enumerated() {
                    let where_ = "\(skin.id)/\(key.rawValue) фаза \(index)"
                    XCTAssertFalse(phase.frames.isEmpty, where_)
                    // The mascot sits on screen all day; anything faster is battery spent
                    // on redrawing a transparent panel.
                    XCTAssertLessThanOrEqual(phase.framesPerSecond, 8, where_)
                    XCTAssertGreaterThanOrEqual(phase.framesPerSecond, 0.6, where_)
                    XCTAssertNotEqual(phase.repeats, 0, "\(where_): нулевое повторение — мёртвая фаза")
                }
            }
        }
    }

    /// Последняя фаза обязана крутиться бесконечно, а все предыдущие — быть
    /// конечными. Иначе движение либо замирает на последнем кадре навсегда, либо
    /// никогда не доходит до покоя, ради которого фазы и заведены.
    func testEveryAnimationEndsInAnEndlessPhaseAndNoneIsUnreachable() {
        for skin in MascotSkins.all {
            for (key, animation) in skin.animations {
                XCTAssertNil(animation.phases.last?.repeats,
                             "\(skin.id)/\(key.rawValue): последняя фаза должна крутиться бесконечно")
                for (index, phase) in animation.phases.dropLast().enumerated() {
                    XCTAssertNotNil(phase.repeats,
                                    "\(skin.id)/\(key.rawValue): фаза \(index) бесконечна, всё за ней недостижимо")
                }
            }
        }
    }

    /// Смысловая проверка того, о чём просили: «закончил» обязано приводить кота к
    /// покою, а не крутить действие без конца. Кадры последней фазы «закончил»
    /// должны совпадать с кадрами сна — то есть кот действительно ложится отдыхать.
    func testDoneSettlesIntoTheRestingPose() {
        for skin in MascotSkins.all {
            guard let done = skin.animation(for: .done),
                  let sleeping = skin.animation(for: .sleeping) else {
                XCTFail("\(skin.id): нет «закончил» или «спит»"); continue
            }
            XCTAssertGreaterThan(done.phases.count, 1,
                                 "\(skin.id): «закончил» должно быть переходом, а не петлёй")
            XCTAssertEqual(done.phases.last?.frames, sleeping.phases.last?.frames,
                           "\(skin.id): «закончил» должно заканчиваться позой покоя")
        }
    }

    func testEverySkinNamesAnAuthorAndASource() {
        for skin in MascotSkins.all {
            XCTAssertFalse(skin.name.isEmpty, skin.id)
            XCTAssertFalse(skin.author.isEmpty, skin.id)
            XCTAssertTrue(skin.sourceURL.hasPrefix("https://"), skin.id)
        }
    }

    /// mxmaze ships under CC BY 4.0, where attribution is an obligation rather than
    /// a courtesy — the credited name has to actually be there. `author` is what
    /// the credits row in `SkinPickerView` actually prints, so that is what this
    /// test guards, not an unread payload on the licence case.
    func testAttributionIsSpelledOutWhereTheLicenceDemandsIt() {
        let demanding = MascotSkins.all.filter { $0.license.requiresAttribution }
        XCTAssertEqual(demanding.map(\.id), ["mxmaze-kitty"])
        for skin in demanding {
            XCTAssertFalse(skin.author.isEmpty, skin.id)
        }
    }

    func testUnknownIDFallsBackToTheDefaultSkin() {
        // Which skin is the default is a product decision, not an implementation
        // detail: pin it directly so a change to `MascotSkins.default` shows up here
        // rather than being absorbed by the relative assertions below.
        XCTAssertEqual(MascotSkins.default.id, "luizmelo-cat-1")
        XCTAssertEqual(MascotSkins.skin(withID: "мусор-из-настроек").id, MascotSkins.default.id)
        XCTAssertEqual(MascotSkins.skin(withID: "").id, MascotSkins.default.id)
        XCTAssertEqual(MascotSkins.skin(withID: "elthen-cat").id, "elthen-cat")
        // Every existing user's `UserDefaults` still says "drawn" — the hand-drawn
        // cat's old id, from before it stopped being selectable. That must resolve
        // to the default skin exactly like any other unrecognised id, silently:
        // it is not the user's error.
        XCTAssertEqual(MascotSkins.skin(withID: "drawn").id, MascotSkins.default.id)
    }

    /// `Cat-3` is the one LuizMelo cat with no `Itch` sheet, so its "problem" state
    /// falls back to `Licking 2` — the substitution most likely to be lost in a
    /// later refactor, so it is asserted directly.
    func testCat3UsesLickingBecauseItHasNoItchSheet() {
        let cat3 = MascotSkins.skin(withID: "luizmelo-cat-3")
        XCTAssertEqual(cat3.animation(for: .problem)?.frames.first?.sheet, "Cat-3-Licking 2.png")
        let cat1 = MascotSkins.skin(withID: "luizmelo-cat-1")
        XCTAssertEqual(cat1.animation(for: .problem)?.frames.first?.sheet, "Cat-1-Itch.png")
    }

    /// mxmaze's bottom row is drawn with the eyes closed. "Done" must not come from
    /// it, or finishing would read as falling asleep.
    func testMxmazeDoneDoesNotUseAClosedEyeFrame() {
        let mx = MascotSkins.skin(withID: "mxmaze-kitty")
        let closedEyeIndices = [6, 7, 8]  // row 2 of the 3x3 sheet
        let done = try? XCTUnwrap(mx.animation(for: .done))
        for frame in done?.frames ?? [] {
            XCTAssertFalse(closedEyeIndices.contains(frame.index),
                           "«закончил» не должен брать кадр с закрытыми глазами")
        }
        XCTAssertEqual(mx.animation(for: .sleeping)?.frames.map(\.index), [7, 8])
    }
}
