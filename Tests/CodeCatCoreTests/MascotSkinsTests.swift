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
        XCTAssertFalse(SkinLicense.authorTerms(summary: "author's terms").requiresAttribution)
    }

    func testAnimationLookupReturnsNilForAMissingState() {
        let skin = MascotSkin(
            id: "test", name: "Test", author: "nobody", license: .cc0,
            sourceURL: "https://example.com", directory: "test", frameSize: 16,
            animations: [.sleeping: SpriteAnimation(
                frames: [SpriteFrame(sheet: "a.png", index: 0)], framesPerSecond: 1)])
        XCTAssertEqual(skin.animation(for: .sleeping)?.frames.count, 1)
        XCTAssertNil(skin.animation(for: .working))
    }

    /// The built-ins keep their square, bundled spelling; it must map onto the new
    /// general shape without changing a thing.
    func testSquareConvenienceInitMapsToABundledLocation() {
        let skin = MascotSkin(id: "t", name: "T", author: "a", license: .cc0,
                              sourceURL: "https://example.com", directory: "dir",
                              frameSize: 16, animations: [:])
        XCTAssertEqual(skin.location, .bundled("dir"))
        XCTAssertEqual(skin.location.bundledPath, "dir")
        XCTAssertEqual(skin.frameWidth, 16)
        XCTAssertEqual(skin.frameHeight, 16)
        XCTAssertNil(skin.note)
    }

    func testExternalSkinKeepsItsFolderAndRectangularFrames() {
        let url = URL(fileURLWithPath: "/tmp/pets/duck", isDirectory: true)
        let skin = MascotSkin(id: "pet:duck", name: "Duck", author: "Duck", license: .cc0,
                              sourceURL: url.path, location: .external(url),
                              frameWidth: 192, frameHeight: 208, bundled: false,
                              note: "quacks", animations: [:])
        XCTAssertEqual(skin.location, .external(url))
        XCTAssertNil(skin.location.bundledPath)
        XCTAssertEqual(skin.frameWidth, 192)
        XCTAssertEqual(skin.frameHeight, 208)
        XCTAssertEqual(skin.note, "quacks")
        XCTAssertNotEqual(SkinLocation.bundled("duck").cacheKey, skin.location.cacheKey)
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
                                "\(skin.id) does not know the state \(key.rawValue)")
            }
        }
    }

    /// Every phase is checked, not only the first: in movements with a transition
    /// ("stretch — lie down — sleep") an empty or too-fast phase in the middle would go
    /// unnoticed exactly where nobody is looking at it.
    func testNoAnimationPhaseIsEmptyOrHasFPSOutsideTheAllowedRange() {
        for skin in MascotSkins.all {
            for (key, animation) in skin.animations {
                XCTAssertFalse(animation.phases.isEmpty, "\(skin.id)/\(key.rawValue)")
                for (index, phase) in animation.phases.enumerated() {
                    let where_ = "\(skin.id)/\(key.rawValue) phase \(index)"
                    XCTAssertFalse(phase.frames.isEmpty, where_)
                    // The mascot sits on screen all day; anything faster is battery spent
                    // on redrawing a transparent panel.
                    XCTAssertLessThanOrEqual(phase.framesPerSecond, 8, where_)
                    XCTAssertGreaterThanOrEqual(phase.framesPerSecond, 0.6, where_)
                    XCTAssertNotEqual(phase.repeats, 0, "\(where_): zero repeats — a dead phase")
                }
            }
        }
    }

    /// The last phase must loop forever and every earlier one must be finite.
    /// Otherwise the movement either freezes on its last frame for good, or never
    /// reaches the rest the phases exist for.
    func testEveryAnimationEndsInAnEndlessPhaseAndNoneIsUnreachable() {
        for skin in MascotSkins.all {
            for (key, animation) in skin.animations {
                XCTAssertNil(animation.phases.last?.repeats,
                             "\(skin.id)/\(key.rawValue): the last phase must loop forever")
                for (index, phase) in animation.phases.dropLast().enumerated() {
                    XCTAssertNotNil(phase.repeats,
                                    "\(skin.id)/\(key.rawValue): phase \(index) is endless, everything after it is unreachable")
                }
            }
        }
    }

    /// The meaning-level check of what was asked for: "done" has to bring the cat to
    /// rest rather than loop an action forever. The last phase of "done" must use the
    /// same frames as sleep — that is, the cat really does lie down to rest.
    func testDoneSettlesIntoTheRestingPose() {
        for skin in MascotSkins.all {
            guard let done = skin.animation(for: .done),
                  let sleeping = skin.animation(for: .sleeping) else {
                XCTFail("\(skin.id): no \"done\" or no \"sleeping\""); continue
            }
            XCTAssertGreaterThan(done.phases.count, 1,
                                 "\(skin.id): \"done\" must be a transition, not a loop")
            XCTAssertEqual(done.phases.last?.frames, sleeping.phases.last?.frames,
                           "\(skin.id): \"done\" must end in the resting pose")
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
    /// the credits row in `CreditsList` actually prints, so that is what this
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
        XCTAssertEqual(MascotSkins.skin(withID: "garbage-from-settings").id, MascotSkins.default.id)
        XCTAssertEqual(MascotSkins.skin(withID: "").id, MascotSkins.default.id)
        XCTAssertEqual(MascotSkins.skin(withID: "elthen-cat").id, "elthen-cat")
        // Every existing user's `UserDefaults` still says "drawn" — the hand-drawn
        // cat's old id, from before it stopped being selectable. That must resolve
        // to the default skin exactly like any other unrecognised id, silently:
        // it is not the user's error.
        XCTAssertEqual(MascotSkins.skin(withID: "drawn").id, MascotSkins.default.id)
    }

    /// 0.5 poses (spec §3). `Meow` lowered the head and opened the mouth and was read
    /// as the cat being sick; `Idle` stood still and read as waiting; `Itch` meant
    /// nothing. Asserted for all six cats because the sheets are per cat and one
    /// missing file would only show on that skin.
    func testLuizMeloPosesSayWhatTheyMean() {
        for n in 1...6 {
            let skin = MascotSkins.skin(withID: "luizmelo-cat-\(n)")
            let working = try? XCTUnwrap(skin.animation(for: .working))
            XCTAssertEqual(working?.frames.map(\.sheet), Array(repeating: "Cat-\(n)-Walk.png", count: 8), "cat \(n)")
            XCTAssertEqual(working?.frames.map(\.index), Array(0..<8), "cat \(n)")
            XCTAssertEqual(working?.phases.first?.framesPerSecond, 8, "cat \(n)")

            let waiting = try? XCTUnwrap(skin.animation(for: .waiting))
            XCTAssertEqual(waiting?.frames, [SpriteFrame(sheet: "Cat-\(n)-Sitting.png", index: 0)], "cat \(n)")
            XCTAssertEqual(waiting?.phases.first?.framesPerSecond, 1, "cat \(n)")

            let problem = try? XCTUnwrap(skin.animation(for: .problem))
            XCTAssertEqual(problem?.frames, [SpriteFrame(sheet: "Cat-\(n)-Run.png", index: 6),
                                             SpriteFrame(sheet: "Cat-\(n)-Run.png", index: 7)], "cat \(n)")
            XCTAssertEqual(problem?.phases.first?.framesPerSecond, 2, "cat \(n)")
        }
    }

    /// mxmaze's bottom row is drawn with the eyes closed. "Done" must not come from
    /// it, or finishing would read as falling asleep.
    func testMxmazeDoneDoesNotUseAClosedEyeFrame() {
        let mx = MascotSkins.skin(withID: "mxmaze-kitty")
        let closedEyeIndices = [6, 7, 8]  // row 2 of the 3x3 sheet
        let done = try? XCTUnwrap(mx.animation(for: .done))
        for frame in done?.frames ?? [] {
            XCTAssertFalse(closedEyeIndices.contains(frame.index),
                           "\"done\" must not take a closed-eye frame")
        }
        XCTAssertEqual(mx.animation(for: .sleeping)?.frames.map(\.index), [7, 8])
    }
}
