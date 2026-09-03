import Foundation

/// The eight sprite skins the app ships with. Every mapping here was built by
/// looking at the files themselves — frame counts come from each sheet's real
/// width, not from the itch.io descriptions.
///
/// The hand-drawn cat (`CatView`, in `CodeCatApp`) is no longer one of these: it is
/// not selectable, only the emergency render used when a sprite skin's sheets fail
/// to load. It has no entry here because it has no sprite data to register.
public enum MascotSkins {

    public static let all: [MascotSkin] = (1...6).map(luizMeloCat) + [elthen, mxmaze]

    /// `luizmelo-cat-1` ("Рыжий"): the warm ginger cat, closest in spirit to the
    /// retired hand-drawn default, and the only LuizMelo cat in a warm palette.
    ///
    /// Built directly rather than looked up in `all`, so this can never fail: a
    /// lookup-based default (`all.first { $0.id == "luizmelo-cat-1" }!`) would trap
    /// at launch if that id were ever renamed or removed from `all`.
    public static let `default` = luizMeloCat(1)

    /// Falls back to `default` rather than failing: an id that is not in the
    /// registry means a corrupted or downgraded `UserDefaults` (including a stored
    /// `"drawn"`, from before the hand-drawn cat stopped being selectable), which
    /// must never leave the user without a mascot.
    public static func skin(withID id: String) -> MascotSkin {
        all.first { $0.id == id } ?? MascotSkins.default
    }

    // MARK: - LuizMelo

    /// Colours read off each cat's `Idle` frame; that is all that distinguishes
    /// `Cat-1`…`Cat-6` in the archive, where they are only numbered. A `switch`
    /// rather than a dictionary lookup: the compiler proves every `1...6` case is
    /// covered, so there is no force-unwrap that could trap on a typo'd number.
    private static func luizMeloName(_ n: Int) -> String {
        switch n {
        case 1: return "Рыжий"
        case 2: return "Чёрный"
        case 3: return "Сиамский"
        case 4: return "Дымчатый"
        case 5: return "Белый"
        case 6: return "Полосатый"
        default: return "Кот \(n)"
        }
    }

    private static func luizMeloCat(_ n: Int) -> MascotSkin {
        MascotSkin(
            id: "luizmelo-cat-\(n)",
            name: luizMeloName(n),
            author: "LuizMelo",
            license: .cc0,
            sourceURL: "https://luizmelo.itch.io/pet-cat-pack",
            directory: "luizmelo/Cat-\(n)",
            frameSize: 50,
            animations: luizMeloAnimations(n))
    }

    private static func luizMeloAnimations(_ n: Int) -> [AggregateStatusKey: SpriteAnimation] {
        func stripFrames(_ name: String, count: Int) -> [SpriteFrame] {
            (0..<count).map { SpriteFrame(sheet: "Cat-\(n)-\(name).png", index: $0) }
        }
        func strip(_ name: String, count: Int, fps: Double) -> SpriteAnimation {
            SpriteAnimation(frames: stripFrames(name, count: count), framesPerSecond: fps)
        }
        let sleepingFrames = [SpriteFrame(sheet: "Cat-\(n)-Sleeping1.png", index: 0),
                              SpriteFrame(sheet: "Cat-\(n)-Sleeping2.png", index: 0)]
        // `Cat-3` is the only cat without an `Itch` sheet. `Licking 2` is the nearest
        // "something is off" motion it does have — and it must come from the same
        // pack, because styles are never mixed.
        let problem = n == 3
            ? strip("Licking 2", count: 5, fps: 6)
            : strip("Itch", count: 2, fps: 3)
        return [
            // Two single-frame files looped slowly read as breathing. `Laying` is not
            // usable here: it is a sit-down-then-lie-down *transition*, so looping it
            // would have the cat standing up and lying down forever.
            .sleeping: SpriteAnimation(frames: sleepingFrames, framesPerSecond: 0.6),
            .working: strip("Idle", count: 10, fps: 8),
            // The cat opens its mouth and calls — the closest thing in the pack to
            // "your agent is asking you something".
            .waiting: strip("Meow", count: 4, fps: 5),
            // Работа закончена: кот потягивается пару раз, укладывается и засыпает.
            // `Laying` — это готовый переход «сесть и лечь» из самого набора: в петле
            // он выглядел бы бесконечным вставанием, а одним проходом ровно тем, чем
            // и является. Потягивание тоже одноразовое по смыслу — крутить его все
            // десять минут, что живёт состояние, значит показывать движение, которого
            // в жизни не бывает.
            .done: SpriteAnimation(phases: [
                SpritePhase(frames: stripFrames("Stretching", count: 13), framesPerSecond: 8, repeats: 2),
                SpritePhase(frames: stripFrames("Laying", count: 8), framesPerSecond: 6, repeats: 1),
                SpritePhase(frames: sleepingFrames, framesPerSecond: 0.6),
            ]),
            .problem: problem,
        ]
    }

    // MARK: - Elthen

    /// One 256x320 sheet, an 8x10 grid of 32x32 frames. Rows are numbered from zero,
    /// so frame index = row * 8 + column.
    ///
    /// `bundled: false` — Elthen's terms forbid redistributing the assets
    /// themselves, so the sheet is not committed to this repository. It is
    /// downloaded onto the build machine by `scripts/fetch-optional-assets.sh`;
    /// when it is absent this skin simply does not appear in the picker.
    private static let elthen = MascotSkin(
        id: "elthen-cat",
        name: "Silver",
        author: "Elthen's Pixel Art Shop",
        license: .authorTerms(summary: "Free to use in projects; the assets themselves may not be resold or redistributed."),
        sourceURL: "https://elthen.itch.io/2d-pixel-art-cat-sprites",
        directory: "elthen",
        frameSize: 32,
        bundled: false,
        animations: {
            let sheet = "Cat Sprite Sheet.png"
            func rowFrames(_ r: Int, _ columns: Range<Int>) -> [SpriteFrame] {
                columns.map { SpriteFrame(sheet: sheet, index: r * 8 + $0) }
            }
            func row(_ r: Int, _ columns: Range<Int>, fps: Double) -> SpriteAnimation {
                SpriteAnimation(frames: rowFrames(r, columns), framesPerSecond: fps)
            }
            return [
                .sleeping: row(6, 0..<4, fps: 2),   // lying flat
                .working: row(0, 0..<4, fps: 6),    // sitting, flicking its tail
                .waiting: row(3, 0..<4, fps: 5),    // raising a paw
                // Умылся после работы — и лёг. Тот же переход к покою, что и у
                // остальных наборов (см. `.done` у LuizMelo).
                .done: SpriteAnimation(phases: [
                    SpritePhase(frames: rowFrames(7, 0..<6), framesPerSecond: 6, repeats: 2),
                    SpritePhase(frames: rowFrames(6, 0..<4), framesPerSecond: 2),
                ]),
                .problem: row(9, 0..<8, fps: 6),    // tail up, alert
            ]
        }())

    // MARK: - mxmaze

    /// One 48x48 sheet, a 3x3 grid of 16x16 frames: row 0 stands, row 1 sits and
    /// raises a paw, row 2 has its eyes closed. Three poses for five states means
    /// collisions are unavoidable; they are placed between the *awake* poses on
    /// purpose. Sleep is the one state that tells the user there is nothing to do,
    /// so nothing else may look like it — which is why "done" takes a still frame
    /// from row 1 rather than the sitting frame (2,0), whose eyes are shut.
    private static let mxmaze = MascotSkin(
        id: "mxmaze-kitty",
        name: "Плюшевый",
        author: "Maze.Bit.Boutique (mxmaze)",
        license: .ccBy4,
        sourceURL: "https://mxmaze.itch.io/16-bit-kitty-free",
        directory: "mxmaze",
        frameSize: 16,
        animations: {
            let sheet = "16x16-Brown.png"
            func cells(_ indices: [Int]) -> [SpriteFrame] {
                indices.map { SpriteFrame(sheet: sheet, index: $0) }
            }
            func frames(_ indices: [Int], fps: Double) -> SpriteAnimation {
                SpriteAnimation(frames: cells(indices), framesPerSecond: fps)
            }
            return [
                .sleeping: frames([7, 8], fps: 0.6),      // (2,1), (2,2): lying, eyes closed
                .working: frames([0, 1, 2], fps: 5),      // row 0
                .waiting: frames([3, 4, 5], fps: 5),      // row 1: raises a paw
                // Раньше здесь стоял один застывший кадр стоящего кота — и он висел
                // так все десять минут, что живёт состояние. Теперь кот садится,
                // укладывается и остаётся лежать: три позы, которые есть в наборе,
                // как раз и складываются в этот переход.
                .done: SpriteAnimation(phases: [
                    SpritePhase(frames: cells([4, 5]), framesPerSecond: 2.5, repeats: 2),
                    SpritePhase(frames: cells([6]), framesPerSecond: 1.2, repeats: 1),
                    SpritePhase(frames: cells([7, 8]), framesPerSecond: 0.6),
                ]),
                // Same as "working"; the badge is what tells them apart.
                .problem: frames([0, 1, 2], fps: 5),
            ]
        }())
}
