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
        func strip(_ name: String, count: Int, fps: Double) -> SpriteAnimation {
            SpriteAnimation(
                frames: (0..<count).map { SpriteFrame(sheet: "Cat-\(n)-\(name).png", index: $0) },
                framesPerSecond: fps)
        }
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
            .sleeping: SpriteAnimation(
                frames: [SpriteFrame(sheet: "Cat-\(n)-Sleeping1.png", index: 0),
                         SpriteFrame(sheet: "Cat-\(n)-Sleeping2.png", index: 0)],
                framesPerSecond: 0.6),
            .working: strip("Idle", count: 10, fps: 8),
            // The cat opens its mouth and calls — the closest thing in the pack to
            // "your agent is asking you something".
            .waiting: strip("Meow", count: 4, fps: 5),
            .done: strip("Stretching", count: 13, fps: 8),
            .problem: problem,
        ]
    }

    // MARK: - Elthen

    /// One 256x320 sheet, an 8x10 grid of 32x32 frames. Rows are numbered from zero,
    /// so frame index = row * 8 + column.
    private static let elthen = MascotSkin(
        id: "elthen-cat",
        name: "Серебристый",
        author: "Elthen's Pixel Art Shop",
        license: .authorTerms(summary: "Разрешено использовать в проектах; сами ассеты нельзя перепродавать и раздавать."),
        sourceURL: "https://elthen.itch.io/2d-pixel-art-cat-sprites",
        directory: "elthen",
        frameSize: 32,
        animations: {
            let sheet = "Cat Sprite Sheet.png"
            func row(_ r: Int, _ columns: Range<Int>, fps: Double) -> SpriteAnimation {
                SpriteAnimation(
                    frames: columns.map { SpriteFrame(sheet: sheet, index: r * 8 + $0) },
                    framesPerSecond: fps)
            }
            return [
                .sleeping: row(6, 0..<4, fps: 2),   // lying flat
                .working: row(0, 0..<4, fps: 6),    // sitting, flicking its tail
                .waiting: row(3, 0..<4, fps: 5),    // raising a paw
                .done: row(7, 0..<6, fps: 6),       // washing
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
            func frames(_ indices: [Int], fps: Double) -> SpriteAnimation {
                SpriteAnimation(
                    frames: indices.map { SpriteFrame(sheet: sheet, index: $0) },
                    framesPerSecond: fps)
            }
            return [
                .sleeping: frames([7, 8], fps: 0.6),      // (2,1), (2,2): lying, eyes closed
                .working: frames([0, 1, 2], fps: 5),      // row 0
                .waiting: frames([3, 4, 5], fps: 5),      // row 1: raises a paw
                // Same pose as "waiting", but held still and without the red badge.
                .done: frames([3], fps: 1),
                // Same as "working"; the badge is what tells them apart.
                .problem: frames([0, 1, 2], fps: 5),
            ]
        }())
}
