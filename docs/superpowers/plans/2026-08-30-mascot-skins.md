# Облики котика — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Дать пользователю выбрать облик маскота из девяти вариантов (нарисованный кот + восемь спрайтовых), переключая их сеткой живых превью в панели деталей.

**Architecture:** Данные обликов (какой файл, какие кадры, с какой скоростью) живут чистой моделью в `CodeCatCore` и тестируются целиком. Слой приложения загружает PNG из `Bundle.module`, один раз считает по пикселям объединяющую рамку облика, из неё выводит целочисленный масштаб и прямоугольник кадрирования, и рисует кадры через `TimelineView(.periodic)`. Бейдж выносится из `CatView` в общий `MascotBadge`, которым пользуются оба вида маскота.

**Tech Stack:** Swift 5.9, SwiftPM, SwiftUI + AppKit, XCTest. Никаких новых зависимостей.

## Global Constraints

- **Язык.** Все строки, видимые пользователю, — по-русски. Комментарии в коде — по-английски (так во всём проекте). Тексты подписей брать из спека дословно.
- **`CodeCatCore` не зависит ни от AppKit, ни от файловой системы.** Всё, что читает файлы или рисует, живёт в `CodeCatApp`. Единственное исключение — тест согласованности с файлами (Задача 4), он в `CodeCatCore` и ходит по `#filePath`.
- **Идентификаторы обликов неизменны:** `drawn`, `luizmelo-cat-1`…`luizmelo-cat-6`, `elthen-cat`, `mxmaze-kitty`. Они попадают в `UserDefaults`; переименование сломает сохранённый выбор пользователя.
- **Правило масштаба:** `S = max(1, min(floor(64 / высота рамки), floor(120 / ширина рамки)))`, где рамка — объединяющая рамка непрозрачных пикселей по всем кадрам всех пяти анимаций облика. Константы: целевая высота 64 pt, предел ширины 120 pt.
- **Рамка кадрирования одна на облик**, а не на анимацию и не на кадр.
- **Отрисовка спрайтов:** `.interpolation(.none)` и только целочисленный масштаб.
- **fps в диапазоне 0.6–8**, у превью в панели — не больше 4.
- **Ключ `UserDefaults`:** `mascotSkin`, значение по умолчанию `drawn`.
- **Никаких молчаливых отказов.** Сообщение не имеет права утверждать то, чего код не знает.
- Тесты запускаются `swift test`; на момент начала работы их 219 и все зелёные.

---

## Структура файлов

Создаются:

| Файл | За что отвечает |
|---|---|
| `Sources/CodeCatCore/MascotSkin.swift` | Типы `SpriteFrame`, `SpriteAnimation`, `SkinLicense`, `AggregateStatusKey`, `MascotSkin` |
| `Sources/CodeCatCore/MascotSkins.swift` | Реестр девяти обликов и поиск по идентификатору |
| `Sources/CodeCatCore/SpriteScale.swift` | Чистое правило масштаба (без картинок, на числах) |
| `Sources/CodeCatApp/Skins/` | Ассеты (переезжают из `Resources/Skins/`) |
| `Sources/CodeCatApp/SpriteSheetStore.swift` | Загрузка PNG, кэш `CGImage`, вычисление рамки и масштаба облика |
| `Sources/CodeCatApp/SpriteMascotView.swift` | Отрисовка кадров спрайтового облика |
| `Sources/CodeCatApp/MascotBadge.swift` | Бейдж числа сессий, общий для нарисованного и спрайтового кота |
| `Sources/CodeCatApp/MascotView.swift` | Выбор между `CatView` и `SpriteMascotView` |
| `Sources/CodeCatApp/SkinPickerView.swift` | Сетка превью и раскрывающаяся строка «Об ассетах» |
| `Tests/CodeCatCoreTests/MascotSkinsTests.swift` | Тесты реестра |
| `Tests/CodeCatCoreTests/SpriteScaleTests.swift` | Тесты правила масштаба |
| `Tests/CodeCatCoreTests/SkinAssetsTests.swift` | Тест согласованности реестра с реальными PNG |

Изменяются: `Package.swift`, `Makefile`, `Sources/CodeCatApp/CatView.swift` (бейдж уезжает), `Sources/CodeCatApp/OverlayPanel.swift` (`CatView` → `MascotView`), `Sources/CodeCatApp/AppState.swift` (выбор облика + алерт об ошибке загрузки), `Sources/CodeCatApp/DetailsPanelView.swift` (вставка `SkinPickerView`), `README.md`.

Порядок задач выбран так, чтобы каждая заканчивалась проверяемым результатом: 1 — типы, 2 — реестр, 3 — правило масштаба, 4 — ассеты на месте и сходятся с реестром, 5 — загрузка листов, 6 — отрисовка маскота, 7 — переключатель в панели, 8 — сборка и документация.

---

## Задача 1: Типы модели обликов

**Files:**
- Create: `Sources/CodeCatCore/MascotSkin.swift`
- Test: `Tests/CodeCatCoreTests/MascotSkinsTests.swift`

**Interfaces:**
- Consumes: `AggregateStatus` из `Sources/CodeCatCore/SessionModel.swift` (случаи `.sleeping`, `.working(Int)`, `.waiting(Int)`, `.done`, `.problem`).
- Produces: `SpriteFrame(sheet:index:)`, `SpriteAnimation(frames:framesPerSecond:)`, `SkinLicense` с `requiresAttribution`, `AggregateStatusKey` с `init(_ status: AggregateStatus)`, `MascotSkin(id:name:author:license:sourceURL:directory:frameSize:animations:)` с `animation(for: AggregateStatusKey) -> SpriteAnimation?`.

- [ ] **Step 1: Write the failing test**

Создать `Tests/CodeCatCoreTests/MascotSkinsTests.swift`:

```swift
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
        XCTAssertTrue(SkinLicense.ccBy4(attributionTo: "кто-то").requiresAttribution)
        XCTAssertFalse(SkinLicense.cc0.requiresAttribution)
        XCTAssertFalse(SkinLicense.authorTerms(summary: "условия автора").requiresAttribution)
        XCTAssertFalse(SkinLicense.builtIn.requiresAttribution)
    }

    func testAnimationLookupReturnsNilForAMissingState() {
        let skin = MascotSkin(
            id: "test", name: "Тестовый", author: "никто", license: .builtIn,
            sourceURL: "https://example.com", directory: nil, frameSize: 16,
            animations: [.sleeping: SpriteAnimation(
                frames: [SpriteFrame(sheet: "a.png", index: 0)], framesPerSecond: 1)])
        XCTAssertEqual(skin.animation(for: .sleeping)?.frames.count, 1)
        XCTAssertNil(skin.animation(for: .working))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MascotSkinsTests`
Expected: FAIL, компилятор не знает `AggregateStatusKey`, `SkinLicense`, `MascotSkin`.

- [ ] **Step 3: Write minimal implementation**

Создать `Sources/CodeCatCore/MascotSkin.swift`:

```swift
import Foundation

/// One frame: which sprite sheet it lives in, and where in that sheet.
///
/// The sheet's column count is deliberately *not* declared anywhere. It is derived
/// at load time from the image's real width (`width / frameSize`), and the frame's
/// position from `index`. Declaring it would be a fourth place where the data could
/// drift away from the file, and LuizMelo's horizontal strips are all different
/// lengths, so each would have to be described separately.
public struct SpriteFrame: Equatable, Sendable {
    /// File name inside the skin's directory.
    public let sheet: String
    /// Frame number within the sheet, left to right then top to bottom.
    public let index: Int

    public init(sheet: String, index: Int) {
        self.sheet = sheet
        self.index = index
    }
}

/// A looping animation for one state.
public struct SpriteAnimation: Equatable, Sendable {
    public let frames: [SpriteFrame]
    public let framesPerSecond: Double

    public init(frames: [SpriteFrame], framesPerSecond: Double) {
        self.frames = frames
        self.framesPerSecond = framesPerSecond
    }
}

/// The terms each pack ships under, re-read from the source pages rather than from
/// any secondary table. Only CC BY 4.0 makes attribution a legal obligation; the
/// rest are shown out of courtesy.
public enum SkinLicense: Equatable, Sendable {
    case cc0
    case ccBy4(attributionTo: String)
    /// Elthen publishes no formal licence — the terms are the author's own words.
    case authorTerms(summary: String)
    /// The hand-drawn cat: ours, no third-party terms involved.
    case builtIn

    public var requiresAttribution: Bool {
        if case .ccBy4 = self { return true }
        return false
    }
}

/// A flat projection of `AggregateStatus`: the animation depends on the *kind* of
/// state, never on the session count, so `.working(1)` and `.working(9)` map to the
/// same key.
public enum AggregateStatusKey: String, CaseIterable, Sendable {
    case sleeping, working, waiting, done, problem

    public init(_ status: AggregateStatus) {
        switch status {
        case .sleeping: self = .sleeping
        case .working: self = .working
        case .waiting: self = .waiting
        case .done: self = .done
        case .problem: self = .problem
        }
    }
}

public struct MascotSkin: Equatable, Sendable, Identifiable {
    /// Persisted in `UserDefaults` — never rename one of these.
    public let id: String
    /// The label the user sees, in Russian.
    public let name: String
    public let author: String
    public let license: SkinLicense
    public let sourceURL: String
    /// Directory holding the sheets inside the app's resources; nil for the drawn cat.
    public let directory: String?
    /// 50 for LuizMelo, 32 for Elthen, 16 for mxmaze.
    public let frameSize: Int
    public let animations: [AggregateStatusKey: SpriteAnimation]

    public init(id: String, name: String, author: String, license: SkinLicense,
                sourceURL: String, directory: String?, frameSize: Int,
                animations: [AggregateStatusKey: SpriteAnimation]) {
        self.id = id
        self.name = name
        self.author = author
        self.license = license
        self.sourceURL = sourceURL
        self.directory = directory
        self.frameSize = frameSize
        self.animations = animations
    }

    /// Whether this skin is drawn from sprite sheets (as opposed to the hand-drawn cat).
    public var isSpriteBased: Bool { directory != nil }

    public func animation(for key: AggregateStatusKey) -> SpriteAnimation? {
        animations[key]
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MascotSkinsTests`
Expected: PASS, три теста.

- [ ] **Step 5: Commit**

```bash
git add Sources/CodeCatCore/MascotSkin.swift Tests/CodeCatCoreTests/MascotSkinsTests.swift
git commit -m "feat: типы модели обликов маскота"
```

---

## Задача 2: Реестр девяти обликов

**Files:**
- Create: `Sources/CodeCatCore/MascotSkins.swift`
- Modify: `Tests/CodeCatCoreTests/MascotSkinsTests.swift` (дописать тесты в конец класса)

**Interfaces:**
- Consumes: типы из Задачи 1.
- Produces: `MascotSkins.all: [MascotSkin]`, `MascotSkins.drawn: MascotSkin`, `MascotSkins.skin(withID: String) -> MascotSkin`.

Таблицы соответствий — из спека, раздел «Таблицы соответствий». Имена файлов LuizMelo содержат пробел (`Cat-3-Licking 2.png`) — это правда, так в архиве.

- [ ] **Step 1: Write the failing test**

Дописать в `Tests/CodeCatCoreTests/MascotSkinsTests.swift`:

```swift
extension MascotSkinsTests {

    /// These ids are persisted in `UserDefaults`. Renaming one silently resets the
    /// user's choice back to the drawn cat, which is why the list is frozen here.
    func testSkinIDsAreExactlyThisFrozenList() {
        XCTAssertEqual(MascotSkins.all.map(\.id), [
            "drawn",
            "luizmelo-cat-1", "luizmelo-cat-2", "luizmelo-cat-3",
            "luizmelo-cat-4", "luizmelo-cat-5", "luizmelo-cat-6",
            "elthen-cat", "mxmaze-kitty",
        ])
    }

    func testEveryStateResolvesForEverySpriteSkin() {
        for skin in MascotSkins.all where skin.isSpriteBased {
            for key in AggregateStatusKey.allCases {
                XCTAssertNotNil(skin.animation(for: key),
                                "\(skin.id) не знает состояния \(key.rawValue)")
            }
        }
    }

    /// The drawn cat is drawn by `CatView`, not from sheets, so it declares no
    /// animations and no directory at all.
    func testDrawnSkinHasNoSpriteData() {
        XCTAssertEqual(MascotSkins.drawn.id, "drawn")
        XCTAssertNil(MascotSkins.drawn.directory)
        XCTAssertTrue(MascotSkins.drawn.animations.isEmpty)
        XCTAssertFalse(MascotSkins.drawn.isSpriteBased)
    }

    func testNoAnimationIsEmptyOrHasNonPositiveFPS() {
        for skin in MascotSkins.all {
            for (key, animation) in skin.animations {
                XCTAssertFalse(animation.frames.isEmpty, "\(skin.id)/\(key.rawValue)")
                XCTAssertGreaterThan(animation.framesPerSecond, 0, "\(skin.id)/\(key.rawValue)")
                // The mascot sits on screen all day; anything faster is battery spent
                // on redrawing a transparent panel.
                XCTAssertLessThanOrEqual(animation.framesPerSecond, 8, "\(skin.id)/\(key.rawValue)")
                XCTAssertGreaterThanOrEqual(animation.framesPerSecond, 0.6, "\(skin.id)/\(key.rawValue)")
            }
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
    /// a courtesy — the credited name has to actually be there.
    func testAttributionIsSpelledOutWhereTheLicenceDemandsIt() {
        let demanding = MascotSkins.all.filter { $0.license.requiresAttribution }
        XCTAssertEqual(demanding.map(\.id), ["mxmaze-kitty"])
        for skin in demanding {
            guard case .ccBy4(let attribution) = skin.license else {
                return XCTFail("\(skin.id): ожидалась лицензия CC BY 4.0")
            }
            XCTAssertFalse(attribution.isEmpty, skin.id)
        }
    }

    func testUnknownIDFallsBackToTheDrawnCat() {
        XCTAssertEqual(MascotSkins.skin(withID: "мусор-из-настроек").id, "drawn")
        XCTAssertEqual(MascotSkins.skin(withID: "").id, "drawn")
        XCTAssertEqual(MascotSkins.skin(withID: "elthen-cat").id, "elthen-cat")
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MascotSkinsTests`
Expected: FAIL, компилятор не знает `MascotSkins`.

- [ ] **Step 3: Write minimal implementation**

Создать `Sources/CodeCatCore/MascotSkins.swift`:

```swift
import Foundation

/// The nine skins the app ships with. Every mapping here was built by looking at the
/// files themselves — frame counts come from each sheet's real width, not from the
/// itch.io descriptions.
public enum MascotSkins {

    /// The hand-drawn cat: the default, and the fallback whenever anything about a
    /// sprite skin goes wrong.
    public static let drawn = MascotSkin(
        id: "drawn",
        name: "Нарисованный",
        author: "CodeCat",
        license: .builtIn,
        sourceURL: "https://github.com/",
        directory: nil,
        frameSize: 0,
        animations: [:])

    public static let all: [MascotSkin] = [drawn] + luizMeloCats + [elthen, mxmaze]

    /// Falls back to the drawn cat rather than failing: an id that is not in the
    /// registry means a corrupted or downgraded `UserDefaults`, which must never
    /// leave the user without a mascot.
    public static func skin(withID id: String) -> MascotSkin {
        all.first { $0.id == id } ?? drawn
    }

    // MARK: - LuizMelo

    /// Colours read off each cat's `Idle` frame; that is all that distinguishes
    /// `Cat-1`…`Cat-6` in the archive, where they are only numbered.
    private static let luizMeloNames = [
        1: "Рыжий", 2: "Чёрный", 3: "Сиамский",
        4: "Дымчатый", 5: "Белый", 6: "Полосатый",
    ]

    private static var luizMeloCats: [MascotSkin] {
        (1...6).map { n in
            MascotSkin(
                id: "luizmelo-cat-\(n)",
                name: luizMeloNames[n]!,
                author: "LuizMelo",
                license: .cc0,
                sourceURL: "https://luizmelo.itch.io/pet-cat-pack",
                directory: "luizmelo/Cat-\(n)",
                frameSize: 50,
                animations: luizMeloAnimations(n))
        }
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
        license: .ccBy4(attributionTo: "Maze.Bit.Boutique (mxmaze), CC BY 4.0"),
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MascotSkinsTests`
Expected: PASS, все тесты класса.

- [ ] **Step 5: Commit**

```bash
git add Sources/CodeCatCore/MascotSkins.swift Tests/CodeCatCoreTests/MascotSkinsTests.swift
git commit -m "feat: реестр девяти обликов маскота"
```

---

## Задача 3: Правило масштаба

**Files:**
- Create: `Sources/CodeCatCore/SpriteScale.swift`
- Test: `Tests/CodeCatCoreTests/SpriteScaleTests.swift`

**Interfaces:**
- Consumes: ничего из предыдущих задач.
- Produces: `SpriteScale.targetHeight: Int` (64), `SpriteScale.maxWidth: Int` (120), `SpriteScale.factor(boundsWidth: Int, boundsHeight: Int) -> Int`.

Правило и обоснование — в спеке, раздел «Масштаб и кадрирование». Считать целыми числами: масштаб обязан быть целым, а деление целых с округлением вниз и есть нужное `floor`.

- [ ] **Step 1: Write the failing test**

Создать `Tests/CodeCatCoreTests/SpriteScaleTests.swift`:

```swift
import XCTest
@testable import CodeCatCore

final class SpriteScaleTests: XCTestCase {

    /// The three packs actually shipped, measured from their pixels: LuizMelo's cats
    /// are 27x14, Elthen's is 18x12, mxmaze's fills its whole 16x16 tile.
    func testTheThreePacksLandOnComparableHeights() {
        XCTAssertEqual(SpriteScale.factor(boundsWidth: 27, boundsHeight: 14), 4)
        XCTAssertEqual(SpriteScale.factor(boundsWidth: 18, boundsHeight: 12), 5)
        XCTAssertEqual(SpriteScale.factor(boundsWidth: 16, boundsHeight: 16), 4)
    }

    /// The whole point of the rule: on-screen heights must not drift apart the way
    /// they did under "normalise the larger side" (which gave 42pt against 96pt).
    func testOnScreenHeightsStayWithinAFewPointsOfEachOther() {
        let heights = [(27, 14), (18, 12), (16, 16)].map { w, h in
            h * SpriteScale.factor(boundsWidth: w, boundsHeight: h)
        }
        XCTAssertEqual(heights, [56, 60, 64])
        XCTAssertLessThanOrEqual(heights.max()! - heights.min()!, 12)
    }

    func testNothingEverExceedsTheCanvasWidth() {
        for w in 1...200 {
            for h in 1...200 {
                let s = SpriteScale.factor(boundsWidth: w, boundsHeight: h)
                XCTAssertGreaterThanOrEqual(s, 1, "\(w)x\(h)")
                if w * s > SpriteScale.maxWidth {
                    // Only a sprite too wide to fit even at 1x may exceed the limit;
                    // there is no smaller integer scale to fall back to.
                    XCTAssertEqual(s, 1, "\(w)x\(h) вышел за предел ширины не на масштабе 1")
                }
            }
        }
    }

    /// A wide, short sprite is capped by width, not by height — this is exactly the
    /// LuizMelo case, where the height rule alone would have asked for 135pt of width.
    func testWideSpriteIsCappedByWidth() {
        // 27x14 at the height rule alone would be floor(64/14) = 4... and 27*5 = 135,
        // so the width cap is what rejects 5.
        XCTAssertEqual(64 / 14, 4)
        XCTAssertEqual(SpriteScale.factor(boundsWidth: 30, boundsHeight: 8), 4)  // 120/30 = 4 wins over 64/8 = 8
    }

    func testDegenerateBoundsNeverProduceZeroOrNegative() {
        XCTAssertEqual(SpriteScale.factor(boundsWidth: 1, boundsHeight: 1), 64)
        XCTAssertEqual(SpriteScale.factor(boundsWidth: 4096, boundsHeight: 4096), 1)
        XCTAssertEqual(SpriteScale.factor(boundsWidth: 0, boundsHeight: 0), 1)
        XCTAssertEqual(SpriteScale.factor(boundsWidth: -5, boundsHeight: -5), 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SpriteScaleTests`
Expected: FAIL, компилятор не знает `SpriteScale`.

- [ ] **Step 3: Write minimal implementation**

Создать `Sources/CodeCatCore/SpriteScale.swift`:

```swift
import Foundation

/// How much a sprite skin is magnified on the mascot canvas.
///
/// The obvious rule — fit the sprite's bounding box into a 96pt square, i.e.
/// `floor(96 / max(width, height))` — does not work here, because the packs draw
/// cats in very different proportions. LuizMelo's cats are four-legged, wide and
/// low (27x14 px), while mxmaze's kitten fills its entire 16x16 tile. Normalising
/// the *larger* side gave LuizMelo 81x42pt and mxmaze 96x96pt: one cat more than
/// twice the height of the other, which reads as two different mascot sizes rather
/// than two skins.
///
/// So height is what gets normalised — height is what the eye reads as "how big is
/// the cat" — with a cap on width so a wide sprite cannot run off the canvas.
public enum SpriteScale {

    /// The height a skin is scaled towards. The drawn cat sits ~87pt tall, but it
    /// sits *upright*; matching four-legged cats to that height would stretch them
    /// to ~160pt wide. 64pt is the compromise that keeps every skin comparable.
    public static let targetHeight = 64

    /// The widest a skin may be drawn. The canvas is `MascotLayout.canvasSize`
    /// (128pt); the remaining slack is left for the badge and the edges.
    public static let maxWidth = 120

    /// Integer magnification for a skin whose union bounding box is
    /// `boundsWidth` x `boundsHeight` pixels. Never returns less than 1: a sprite
    /// too large to fit is drawn at 1x rather than vanishing.
    public static func factor(boundsWidth: Int, boundsHeight: Int) -> Int {
        guard boundsWidth > 0, boundsHeight > 0 else { return 1 }
        return max(1, min(targetHeight / boundsHeight, maxWidth / boundsWidth))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SpriteScaleTests`
Expected: PASS, пять тестов.

- [ ] **Step 5: Commit**

```bash
git add Sources/CodeCatCore/SpriteScale.swift Tests/CodeCatCoreTests/SpriteScaleTests.swift
git commit -m "feat: правило масштаба спрайтовых обликов"
```

---

## Задача 4: Ассеты внутри таргета и тест согласованности

**Files:**
- Move: `Resources/Skins/` → `Sources/CodeCatApp/Skins/` (через `git mv`)
- Modify: `Package.swift`
- Modify: `Sources/CodeCatApp/Skins/CREDITS.md`
- Create: `Tests/CodeCatCoreTests/SkinAssetsTests.swift`

**Interfaces:**
- Consumes: `MascotSkins.all` из Задачи 2.
- Produces: каталог ресурсов `Skins` внутри таргета `CodeCatApp`, доступный через `Bundle.module`; ничего в коде.

Почему тест живёт в `CodeCatCore`, а не в тестах приложения: у таргета `CodeCatApp` тестов нет (это executable), поэтому единственный способ сверить реестр с файлами — пойти от `#filePath` теста к каталогу исходников. Этот тест смотрит на **исходники**; проверка того, что ассеты доехали до собранного `.app`, — отдельная, в Задаче 8.

- [ ] **Step 1: Write the failing test**

Создать `Tests/CodeCatCoreTests/SkinAssetsTests.swift`:

```swift
import XCTest
import CoreGraphics
import ImageIO
@testable import CodeCatCore

/// Checks the registry against the real PNGs. This is the test that catches a typo
/// in a frame table before the app is ever launched.
///
/// It reaches the files through `#filePath` because the sheets live in the
/// `CodeCatApp` target's resources, and an executable target has no test bundle of
/// its own to read them from. That also means this test verifies the *sources*: that
/// the assets survive into the built `.app` is a separate check, in `make app`.
final class SkinAssetsTests: XCTestCase {

    private var skinsDirectory: URL {
        URL(fileURLWithPath: #filePath)            // .../Tests/CodeCatCoreTests/SkinAssetsTests.swift
            .deletingLastPathComponent()           // .../Tests/CodeCatCoreTests
            .deletingLastPathComponent()           // .../Tests
            .deletingLastPathComponent()           // repo root
            .appendingPathComponent("Sources/CodeCatApp/Skins")
    }

    func testSkinsDirectoryExists() {
        XCTAssertTrue(FileManager.default.fileExists(atPath: skinsDirectory.path),
                      "Ассеты обликов не найдены: \(skinsDirectory.path)")
    }

    func testEveryDeclaredSheetExistsAndHoldsEveryDeclaredFrame() throws {
        for skin in MascotSkins.all where skin.isSpriteBased {
            let directory = skinsDirectory.appendingPathComponent(skin.directory!)
            // Highest frame index actually asked for, per sheet.
            var maxIndex: [String: Int] = [:]
            for animation in skin.animations.values {
                for frame in animation.frames {
                    maxIndex[frame.sheet] = max(maxIndex[frame.sheet] ?? 0, frame.index)
                }
            }
            for (sheet, highest) in maxIndex {
                let url = directory.appendingPathComponent(sheet)
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                              "\(skin.id): нет файла \(url.path)")
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    return XCTFail("\(skin.id): не читается PNG \(sheet)")
                }
                let columns = image.width / skin.frameSize
                let rows = image.height / skin.frameSize
                XCTAssertGreaterThan(columns, 0, "\(skin.id)/\(sheet): ширина меньше кадра")
                XCTAssertGreaterThan(rows, 0, "\(skin.id)/\(sheet): высота меньше кадра")
                XCTAssertLessThan(highest, columns * rows,
                                  "\(skin.id)/\(sheet): кадр \(highest) вне листа \(columns)x\(rows)")
                XCTAssertEqual(image.width % skin.frameSize, 0,
                               "\(skin.id)/\(sheet): ширина не кратна кадру \(skin.frameSize)")
                XCTAssertEqual(image.height % skin.frameSize, 0,
                               "\(skin.id)/\(sheet): высота не кратна кадру \(skin.frameSize)")
            }
        }
    }

    /// The licence texts shipped by the authors are kept verbatim, not paraphrased.
    func testOriginalLicenceFilesAreKept() {
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: skinsDirectory.appendingPathComponent("luizmelo/License.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: skinsDirectory.appendingPathComponent("CREDITS.md").path))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SkinAssetsTests`
Expected: FAIL — `Sources/CodeCatApp/Skins` пока не существует.

- [ ] **Step 3: Переместить ассеты и объявить их ресурсами**

```bash
git mv Resources/Skins Sources/CodeCatApp/Skins
```

Изменить `Package.swift`, строку с таргетом `CodeCatApp`:

```swift
        .executableTarget(
            name: "CodeCatApp",
            dependencies: ["CodeCatCore"],
            resources: [.copy("Skins")]),
```

В `Sources/CodeCatApp/Skins/CREDITS.md` заменить абзац, начинающийся со слов «Каталог временный», на:

```markdown
Ассеты объявлены ресурсами таргета `CodeCatApp` в `Package.swift` (`.copy("Skins")`)
и доступны в коде через `Bundle.module`.

**Про условие Elthen «нельзя раздавать сами ассеты».** Репозиторий локальный, без
remote, поэтому файлы никуда не раздаются, а внутри собранного `.app` это обычное
использование. Если репозиторий когда-нибудь станет публичным, лист Elthen из него
удаляется, а его место занимает `fetch-assets.sh`, скачивающий лист с itch.io на
машину пользователя. У LuizMelo (CC0) и mxmaze (CC BY 4.0) такого ограничения нет.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SkinAssetsTests`
Expected: PASS, три теста.

Затем: `swift build 2>&1 | grep -i "unhandled\|warning: found"` — не должно быть предупреждений про необработанные файлы.

- [ ] **Step 5: Commit**

```bash
git add -A Package.swift Sources/CodeCatApp/Skins Resources Tests/CodeCatCoreTests/SkinAssetsTests.swift
git commit -m "feat: ассеты обликов переехали в ресурсы таргета CodeCatApp"
```

---

## Задача 5: Загрузка листов, рамка и масштаб облика

**Files:**
- Create: `Sources/CodeCatApp/SpriteSheetStore.swift`

**Interfaces:**
- Consumes: `MascotSkin`, `SpriteFrame`, `SpriteAnimation`, `AggregateStatusKey` (Задачи 1–2), `SpriteScale.factor(boundsWidth:boundsHeight:)` (Задача 3).
- Produces:
  - `struct LoadedSkin { let skin: MascotSkin; let scale: Int; let bounds: CGRect }` — `bounds` в пикселях внутри кадра, общая на облик.
  - `final class SpriteSheetStore` с `func load(_ skin: MascotSkin) -> LoadedSkin?` (nil, если хоть один лист не читается) и `func image(for frame: SpriteFrame, of skin: MascotSkin, cropping bounds: CGRect) -> CGImage?`.

Тестов у этого файла нет: он читает файлы и работает с `CoreGraphics` — это слой приложения, где в проекте юнит-тестов не пишут. Правильность проверяется Задачей 6 (рендер в PNG) и запуском.

- [ ] **Step 1: Написать реализацию**

Создать `Sources/CodeCatApp/SpriteSheetStore.swift`:

```swift
import AppKit
import CoreGraphics
import ImageIO
import CodeCatCore

/// A skin whose sheets have been read, measured and cached.
struct LoadedSkin {
    let skin: MascotSkin
    /// Integer magnification, from `SpriteScale`.
    let scale: Int
    /// The union of every frame's opaque-pixel bounding box, in sheet pixels,
    /// expressed relative to a single frame's origin. One rectangle for the whole
    /// skin — deliberately not one per animation: LuizMelo's sleeping cat is 22x5
    /// while its working cat is 21x14, so a per-animation crop would jolt the cat
    /// around the canvas every time the state changed.
    let bounds: CGRect

    /// On-screen size of the drawing, in points.
    var drawingSize: CGSize {
        CGSize(width: bounds.width * CGFloat(scale), height: bounds.height * CGFloat(scale))
    }
}

/// Loads sprite sheets out of the app bundle and keeps them in memory. Everything
/// together is under 120 KB, so nothing is ever evicted.
///
/// Every failure path returns nil rather than throwing: the caller's answer is
/// always the same — fall back to the drawn cat and say so once.
final class SpriteSheetStore {

    static let shared = SpriteSheetStore()

    private var sheets: [String: CGImage] = [:]      // keyed by "<directory>/<sheet>"
    private var loaded: [String: LoadedSkin] = [:]   // keyed by skin id
    private var failed: Set<String> = []             // skin ids already known to be broken

    /// Reads, measures and caches a skin. Returns nil if any declared sheet is
    /// missing or unreadable, or if the skin turns out to be fully transparent.
    func load(_ skin: MascotSkin) -> LoadedSkin? {
        guard skin.isSpriteBased else { return nil }
        if let cached = loaded[skin.id] { return cached }
        if failed.contains(skin.id) { return nil }

        var union: CGRect = .null
        for animation in skin.animations.values {
            for frame in animation.frames {
                guard let sheet = sheet(named: frame.sheet, of: skin),
                      let rect = frameRect(frame, of: skin, in: sheet),
                      let opaque = opaqueBounds(of: sheet, in: rect) else {
                    failed.insert(skin.id)
                    return nil
                }
                union = union.union(opaque)
            }
        }
        guard !union.isNull, union.width >= 1, union.height >= 1 else {
            failed.insert(skin.id)
            return nil
        }
        let result = LoadedSkin(
            skin: skin,
            scale: SpriteScale.factor(boundsWidth: Int(union.width), boundsHeight: Int(union.height)),
            bounds: union)
        loaded[skin.id] = result
        return result
    }

    /// The cropped, unscaled image for one frame. Cropping uses the skin-wide
    /// `bounds`, so the cat keeps its place across states while motion *within* an
    /// animation is preserved in full.
    func image(for frame: SpriteFrame, of skin: MascotSkin, cropping bounds: CGRect) -> CGImage? {
        guard let sheet = sheet(named: frame.sheet, of: skin),
              let rect = frameRect(frame, of: skin, in: sheet) else { return nil }
        let crop = CGRect(x: rect.origin.x + bounds.origin.x,
                          y: rect.origin.y + bounds.origin.y,
                          width: bounds.width, height: bounds.height)
        return sheet.cropping(to: crop)
    }

    // MARK: - Sheets

    private func sheet(named name: String, of skin: MascotSkin) -> CGImage? {
        guard let directory = skin.directory else { return nil }
        let key = "\(directory)/\(name)"
        if let cached = sheets[key] { return cached }
        // `.copy("Skins")` keeps the directory tree, so the sheet sits at
        // Skins/<directory>/<name> inside the resource bundle.
        guard let url = Bundle.module.url(forResource: "Skins/\(key)", withExtension: nil),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        sheets[key] = image
        return image
    }

    /// Where a frame sits in its sheet. The column count comes from the image's real
    /// width, never from declared data — see `SpriteFrame`.
    private func frameRect(_ frame: SpriteFrame, of skin: MascotSkin, in sheet: CGImage) -> CGRect? {
        let size = skin.frameSize
        guard size > 0 else { return nil }
        let columns = sheet.width / size
        let rows = sheet.height / size
        guard columns > 0, rows > 0, frame.index >= 0, frame.index < columns * rows else { return nil }
        return CGRect(x: CGFloat((frame.index % columns) * size),
                      y: CGFloat((frame.index / columns) * size),
                      width: CGFloat(size), height: CGFloat(size))
    }

    // MARK: - Measuring

    /// Bounding box of the non-transparent pixels inside `rect`, returned relative to
    /// `rect`'s own origin. Nil when the region is fully transparent.
    ///
    /// The sheet is drawn into a known 8-bit RGBA buffer rather than reading the
    /// PNG's own bytes, so the alpha layout is fixed and does not depend on how the
    /// file happens to be encoded.
    private func opaqueBounds(of sheet: CGImage, in rect: CGRect) -> CGRect? {
        guard let tile = sheet.cropping(to: rect) else { return nil }
        let width = tile.width, height = tile.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
                data: &pixels, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(tile, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 8 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // `CGContext` draws bottom-up while `cropping(to:)` addresses the image
        // top-down, so the vertical span is flipped back here.
        return CGRect(x: CGFloat(minX), y: CGFloat(height - 1 - maxY),
                      width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1))
    }
}
```

- [ ] **Step 2: Проверить, что собирается**

Run: `swift build 2>&1 | tail -20`
Expected: сборка без ошибок и без предупреждений в новом файле.

- [ ] **Step 3: Проверить измерение на реальных файлах**

Написать временную проверку — самый быстрый способ убедиться, что рамка и масштаб совпали с посчитанными в спеке. Добавить в `Sources/CodeCatApp/main.swift` **временно**, в самое начало, до создания приложения:

```swift
if CommandLine.arguments.contains("--dump-skin-metrics") {
    for skin in MascotSkins.all where skin.isSpriteBased {
        if let loaded = SpriteSheetStore.shared.load(skin) {
            print("\(skin.id): рамка \(Int(loaded.bounds.width))x\(Int(loaded.bounds.height)), " +
                  "масштаб \(loaded.scale), на экране \(Int(loaded.drawingSize.width))x\(Int(loaded.drawingSize.height))")
        } else {
            print("\(skin.id): НЕ ЗАГРУЗИЛСЯ")
        }
    }
    exit(0)
}
```

Run: `swift run CodeCatApp --dump-skin-metrics`

Expected — ровно эти строки (числа из спека, посчитанные по пикселям заранее):

```
luizmelo-cat-1: рамка 27x14, масштаб 4, на экране 108x56
...
elthen-cat: рамка 18x12, масштаб 5, на экране 90x60
mxmaze-kitty: рамка 16x16, масштаб 4, на экране 64x64
```

Рамки котов `Cat-2`…`Cat-6` могут отличаться от `Cat-1` на пиксель-другой — это нормально, они нарисованы отдельно. **Не нормально:** «НЕ ЗАГРУЗИЛСЯ», масштаб 1 или высота на экране вне диапазона 48–64. Если так — разбираться с путём в `Bundle.module` или с измерением, а не подгонять числа.

- [ ] **Step 4: Убрать временный код**

Удалить блок `--dump-skin-metrics` из `main.swift`.

Run: `swift build && swift test`
Expected: сборка чистая, все тесты зелёные.

- [ ] **Step 5: Commit**

```bash
git add Sources/CodeCatApp/SpriteSheetStore.swift
git commit -m "feat: загрузка спрайт-листов, рамка и масштаб облика"
```

---

## Задача 6: Отрисовка маскота — бейдж, спрайтовый вид, выбор вида

**Files:**
- Create: `Sources/CodeCatApp/MascotBadge.swift`
- Create: `Sources/CodeCatApp/SpriteMascotView.swift`
- Create: `Sources/CodeCatApp/MascotView.swift`
- Modify: `Sources/CodeCatApp/CatView.swift` (убрать бейдж, взять общий)
- Modify: `Sources/CodeCatApp/AppState.swift` (свойство `skinID`, алерт об ошибке загрузки)
- Modify: `Sources/CodeCatApp/OverlayPanel.swift:216` (`CatView` → `MascotView`)

**Interfaces:**
- Consumes: `LoadedSkin`, `SpriteSheetStore.shared` (Задача 5), `MascotSkins.skin(withID:)` (Задача 2), `AggregateStatusKey(_:)` (Задача 1), `MascotLayout.canvasSize` (существует).
- Produces:
  - `struct MascotBadge: View { let sessionCount: Int; let status: AggregateStatus }`
  - `struct SpriteMascotView: View { let loaded: LoadedSkin; let status: AggregateStatus; let sessionCount: Int; var maxFPS: Double = 8; var showsBadge: Bool = true }`
  - `struct MascotView: View { let skin: MascotSkin; let status: AggregateStatus; let sessionCount: Int }`
  - `AppState.skinID: String` (`@Published`, пишется в `UserDefaults` ключом `mascotSkin`), `AppState.skin: MascotSkin`, `AppState.reportSkinLoadFailure(_ skin: MascotSkin)`.

- [ ] **Step 1: Вынести бейдж в общий вид**

Создать `Sources/CodeCatApp/MascotBadge.swift`:

```swift
import SwiftUI
import CodeCatCore

/// The session-count badge, shared by every mascot skin. It lives outside `CatView`
/// because a sprite skin must show exactly the same badge, in exactly the same
/// place: with five states mapped onto packs that have as few as three poses, the
/// badge is often the only thing telling two states apart.
///
/// Opaque fill (never `.opacity(...)`) plus a light stroke so the badge stays
/// legible whether the desktop behind the transparent panel is light or dark. A
/// `Capsule` renders as a circle for the single-digit case (equal width and height)
/// and grows horizontally for two- or three-digit counts instead of clipping a
/// fixed-size circle.
struct MascotBadge: View {
    let sessionCount: Int
    let status: AggregateStatus

    private var isSleeping: Bool { if case .sleeping = status { return true }; return false }
    private var isWaiting: Bool { if case .waiting = status { return true }; return false }

    var body: some View {
        Group {
            if sessionCount > 0 && !isSleeping {
                if isWaiting {
                    // Waiting stays the most attention-grabbing state: opaque red,
                    // plus a gentle pulse so it reads as needing input.
                    content(fill: Color(red: 0.86, green: 0.15, blue: 0.15))
                        .phaseAnimator([false, true]) { content, pulsePhase in
                            content.scaleEffect(pulsePhase ? 1.15 : 1.0)
                        } animation: { _ in .easeInOut(duration: 1.0) }
                } else {
                    content(fill: Color(white: 0.32))
                }
            }
        }
    }

    private func content(fill: Color) -> some View {
        Text("\(sessionCount)")
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 4)
            .frame(minWidth: 18, minHeight: 18)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5))
            .offset(x: 34, y: -34)
    }
}
```

В `Sources/CodeCatApp/CatView.swift` удалить весь раздел `// MARK: - Badge` (свойство `badge` и метод `badgeContent`) и заменить в `body` строку `badge` на:

```swift
            MascotBadge(sessionCount: sessionCount, status: status)
```

- [ ] **Step 2: Проверить, что нарисованный кот не изменился**

Run: `swift build && swift test`
Expected: сборка чистая, 219+ тестов зелёные.

Дальше — визуально, в Задаче 6, шаг 6: бейдж должен остаться там же, где был.

- [ ] **Step 3: Написать спрайтовый вид**

Создать `Sources/CodeCatApp/SpriteMascotView.swift`:

```swift
import SwiftUI
import CodeCatCore

/// Draws the current frame of a sprite skin.
///
/// Two rules make pixel art survive on screen: `.interpolation(.none)` and an
/// integer magnification. Anything else turns a 16x16 kitten into mush.
struct SpriteMascotView: View {
    let loaded: LoadedSkin
    let status: AggregateStatus
    let sessionCount: Int
    /// Previews in the details panel cap this: nine animations run at once there.
    var maxFPS: Double = 8
    var showsBadge: Bool = true

    private var animation: SpriteAnimation? {
        loaded.skin.animation(for: AggregateStatusKey(status))
    }

    var body: some View {
        ZStack {
            if let animation, !animation.frames.isEmpty {
                let fps = min(max(animation.framesPerSecond, 0.1), maxFPS)
                TimelineView(.periodic(from: .now, by: 1 / fps)) { context in
                    frameImage(at: frameIndex(for: context.date, fps: fps, count: animation.frames.count),
                               in: animation)
                }
            }
            if showsBadge {
                MascotBadge(sessionCount: sessionCount, status: status)
            }
        }
        .frame(width: MascotLayout.canvasSize, height: MascotLayout.canvasSize)
    }

    /// Frame number from wall-clock time rather than a stored counter: `TimelineView`
    /// re-evaluates this body on every tick, and a view that is torn down and
    /// rebuilt (the panel closing, the skin changing) must not restart mid-motion or
    /// hold state that outlives it.
    private func frameIndex(for date: Date, fps: Double, count: Int) -> Int {
        let ticks = Int((date.timeIntervalSinceReferenceDate * fps).rounded(.down))
        return ((ticks % count) + count) % count
    }

    @ViewBuilder
    private func frameImage(at index: Int, in animation: SpriteAnimation) -> some View {
        if let cgImage = SpriteSheetStore.shared.image(
            for: animation.frames[index], of: loaded.skin, cropping: loaded.bounds) {
            Image(decorative: cgImage, scale: 1)
                .interpolation(.none)
                .antialiased(false)
                .resizable()
                .frame(width: loaded.drawingSize.width, height: loaded.drawingSize.height)
        }
    }
}
```

- [ ] **Step 4: Написать выбор вида маскота**

Создать `Sources/CodeCatApp/MascotView.swift`:

```swift
import SwiftUI
import CodeCatCore

/// Picks between the hand-drawn cat and a sprite skin.
///
/// A sprite skin that fails to load falls back to the drawn cat right here, so the
/// mascot is never missing — the user is told about it separately, once, by
/// `AppState.reportSkinLoadFailure`.
struct MascotView: View {
    let skin: MascotSkin
    let status: AggregateStatus
    let sessionCount: Int
    /// Called when a sprite skin could not be loaded, so the app can report it.
    var onLoadFailure: (MascotSkin) -> Void = { _ in }

    var body: some View {
        if skin.isSpriteBased, let loaded = SpriteSheetStore.shared.load(skin) {
            SpriteMascotView(loaded: loaded, status: status, sessionCount: sessionCount)
        } else {
            CatView(status: status, sessionCount: sessionCount)
                .onAppear {
                    if skin.isSpriteBased { onLoadFailure(skin) }
                }
        }
    }
}
```

- [ ] **Step 5: Подключить выбор облика к состоянию приложения**

В `Sources/CodeCatApp/AppState.swift` добавить рядом с `showMascot`:

```swift
    /// Id of the selected skin. Persisted so the choice survives a restart; read
    /// back through `MascotSkins.skin(withID:)`, which falls back to the drawn cat
    /// for anything it does not recognise.
    @Published var skinID: String {
        didSet { UserDefaults.standard.set(skinID, forKey: "mascotSkin") }
    }

    var skin: MascotSkin { MascotSkins.skin(withID: skinID) }

    /// Skins already reported as broken. A failed load is reported once per launch:
    /// the view that renders the mascot is rebuilt constantly, and an alert on every
    /// rebuild would be unusable.
    private var reportedSkinFailures: Set<String> = []
```

В `init()`, в вызов `defaults.register(defaults:)`, добавить `"mascotSkin": "drawn"`, и следом за `showMascot = defaults.bool(forKey: "showMascot")`:

```swift
        skinID = defaults.string(forKey: "mascotSkin") ?? MascotSkins.drawn.id
```

Добавить метод рядом с `presentJumpAlert` (ниже него):

```swift
    /// Reports a skin whose sheets could not be read, and switches back to the drawn
    /// cat. Told with an alert rather than a line in the details panel because the
    /// panel may well be closed — this project's rule is that there are no silent
    /// refusals.
    func reportSkinLoadFailure(_ skin: MascotSkin) {
        guard !reportedSkinFailures.contains(skin.id) else { return }
        reportedSkinFailures.insert(skin.id)
        if skinID == skin.id { skinID = MascotSkins.drawn.id }
        // Same activation dance as `presentJumpAlert`: CodeCat is an accessory app
        // and its windows do not come forward on their own.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Не удалось загрузить облик «\(skin.name)»"
        alert.informativeText = "Файлы набора не читаются. Вернул нарисованного кота."
        alert.window.level = .modalPanel
        alert.window.orderFrontRegardless()
        alert.runModal()
    }
```

В `Sources/CodeCatApp/OverlayPanel.swift` заменить тело `CatClickContent.body` (строка 216):

```swift
        MascotView(skin: appState.skin,
                   status: appState.store.aggregate,
                   sessionCount: appState.store.ordered.count,
                   onLoadFailure: { [appState] skin in appState.reportSkinLoadFailure(skin) })
            .contentShape(Rectangle())
```

Порядок аргументов — тот же, что в объявлении `MascotView` (`skin`, `status`, `sessionCount`, `onLoadFailure`); Swift требует именно его.

- [ ] **Step 6: Проверить рендером в PNG**

Это обязательный шаг: в этом проекте самый тяжёлый дефект MVP (анимации, навешенные на `EmptyView()`, из-за чего кот рисовался без тела) не увидели ни имплементер, ни ревьюер — его нашли только рендером.

Собрать стенд:

```bash
mkdir -p /tmp/skinrig/Sources/skinrig
cd /tmp/skinrig
```

Создать `/tmp/skinrig/Package.swift`:

```swift
// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "skinrig",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "<АБСОЛЮТНЫЙ ПУТЬ К РЕПОЗИТОРИЮ>")],
    targets: [.executableTarget(name: "skinrig", dependencies: [
        .product(name: "CodeCatCore", package: "CodeCat")])]
)
```

Скопировать в `/tmp/skinrig/Sources/skinrig/` файлы `SpriteSheetStore.swift`, `SpriteMascotView.swift`, `MascotBadge.swift`, `MascotView.swift`, `CatView.swift` из репозитория, а также каталог `Skins` (в стенде `Bundle.module` укажет на ресурсы стенда, поэтому в `Package.swift` стенда нужен `resources: [.copy("Skins")]`).

Создать `/tmp/skinrig/Sources/skinrig/main.swift`:

```swift
import SwiftUI
import AppKit
import CodeCatCore

@MainActor
func render(_ view: some View, to path: String) {
    let renderer = ImageRenderer(content: view.frame(width: 128, height: 128))
    renderer.scale = 2
    guard let image = renderer.nsImage,
          let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
}

let states: [(String, AggregateStatus)] = [
    ("sleeping", .sleeping), ("working", .working(1)), ("waiting", .waiting(2)),
    ("done", .done), ("problem", .problem),
]

MainActor.assumeIsolated {
    for skin in MascotSkins.all {
        for (name, status) in states {
            render(MascotView(skin: skin, status: status, sessionCount: 2),
                   to: "/tmp/skinrig/out/\(skin.id)-\(name).png")
        }
    }
}
```

```bash
mkdir -p /tmp/skinrig/out && swift run skinrig
```

Посмотреть **все 45 PNG глазами** (не только пару). Что проверяется:

1. Кот виден в каждом состоянии каждого облика — не пустой прозрачный квадрат.
2. Пиксели резкие, без размытия по краям.
3. Бейдж «2» на своём месте — там же, где у нарисованного кота; в `waiting` он красный.
4. Внутри одного облика кот **не прыгает** между состояниями: центр примерно там же.
5. У `mxmaze-kitty` состояние `done` — с открытыми глазами, а `sleeping` — с закрытыми.
6. Размер котов сопоставим между обликами (высоты 56/60/64 pt на холсте 128).

Если что-то из этого не сходится — чинить, а не списывать на «так задумано».

- [ ] **Step 7: Убрать стенд и закоммитить**

```bash
rm -rf /tmp/skinrig
cd <репозиторий> && swift build && swift test
git add Sources/CodeCatApp/MascotBadge.swift Sources/CodeCatApp/SpriteMascotView.swift Sources/CodeCatApp/MascotView.swift Sources/CodeCatApp/CatView.swift Sources/CodeCatApp/AppState.swift Sources/CodeCatApp/OverlayPanel.swift
git commit -m "feat: отрисовка спрайтовых обликов маскота"
```

---

## Задача 7: Переключатель обликов в панели деталей

**Files:**
- Create: `Sources/CodeCatApp/SkinPickerView.swift`
- Modify: `Sources/CodeCatApp/DetailsPanelView.swift`

**Interfaces:**
- Consumes: `AppState.skinID`, `AppState.skin` (Задача 6), `MascotSkins.all` (Задача 2), `SpriteMascotView`, `MascotView` (Задача 6), `SpriteSheetStore.shared` (Задача 5).
- Produces: `struct SkinPickerView: View { @ObservedObject var appState: AppState }`.

Панель шириной 290 pt: сетка 5 колонок × 2 ряда, превью 34 pt. Горизонтальной прокрутки быть не должно — панель всплывающая, промахнуться мимо неё легко.

- [ ] **Step 1: Написать переключатель**

Создать `Sources/CodeCatApp/SkinPickerView.swift`:

```swift
import SwiftUI
import CodeCatCore

/// The skin picker: a grid of live previews plus the credits disclosure.
///
/// Nine previews at 36pt would not fit the 290pt panel in one row, and horizontal
/// scrolling inside a popover that closes on any click outside it is a way to miss,
/// not a way to choose — hence a 5x2 grid that fits whole.
struct SkinPickerView: View {
    @ObservedObject var appState: AppState
    @State private var creditsExpanded = false

    /// Previews are small and there are nine of them animating at once, so their
    /// frame rate is capped well below the mascot's own.
    private let previewFPS: Double = 4
    private let previewSize: CGFloat = 34

    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(previewSize), spacing: 8), count: 5)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Облик").font(.system(size: 12, weight: .medium))
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(MascotSkins.all) { skin in
                    preview(skin)
                }
            }
            credits
        }
    }

    private func preview(_ skin: MascotSkin) -> some View {
        let isSelected = skin.id == appState.skinID
        return ZStack {
            // Every preview plays the "waiting" animation: that is the state the
            // mascot exists for. The badge is suppressed here — at 34pt it would
            // cover the cat, and the preview is about the artwork, not the count.
            previewContent(skin)
                .frame(width: MascotLayout.canvasSize, height: MascotLayout.canvasSize)
                .scaleEffect(previewSize / MascotLayout.canvasSize)
                .frame(width: previewSize, height: previewSize)
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2))
        .contentShape(Rectangle())
        .onTapGesture { appState.skinID = skin.id }
        .help(skin.name)
        .accessibilityLabel(skin.name)
    }

    @ViewBuilder
    private func previewContent(_ skin: MascotSkin) -> some View {
        if skin.isSpriteBased, let loaded = SpriteSheetStore.shared.load(skin) {
            SpriteMascotView(loaded: loaded, status: .waiting(1), sessionCount: 0,
                             maxFPS: previewFPS, showsBadge: false)
        } else {
            CatView(status: .waiting(1), sessionCount: 0)
        }
    }

    private var credits: some View {
        DisclosureGroup("Об ассетах", isExpanded: $creditsExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(creditedPacks, id: \.author) { pack in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(pack.author).font(.system(size: 11, weight: .medium))
                        Text(pack.license).font(.system(size: 10)).foregroundStyle(.secondary)
                        Link(pack.sourceURL, destination: URL(string: pack.sourceURL)!)
                            .font(.system(size: 10))
                    }
                }
            }
            .padding(.top, 4)
        }
        .font(.system(size: 11))
    }

    /// One entry per pack, not per skin: six LuizMelo cats share one author and one
    /// licence, and repeating them six times would bury the one line that is an
    /// actual obligation (mxmaze is CC BY 4.0, where attribution is required).
    private var creditedPacks: [(author: String, license: String, sourceURL: String)] {
        var seen = Set<String>()
        var result: [(author: String, license: String, sourceURL: String)] = []
        for skin in MascotSkins.all where skin.isSpriteBased {
            guard seen.insert(skin.author).inserted else { continue }
            result.append((author: skin.author,
                           license: licenseText(skin.license),
                           sourceURL: skin.sourceURL))
        }
        return result
    }

    private func licenseText(_ license: SkinLicense) -> String {
        switch license {
        case .cc0: return "CC0 1.0 — общественное достояние"
        case .ccBy4(let attribution): return "CC BY 4.0 — \(attribution)"
        case .authorTerms(let summary): return summary
        case .builtIn: return "Нарисован для CodeCat"
        }
    }
}
```

- [ ] **Step 2: Вставить переключатель в панель**

В `Sources/CodeCatApp/DetailsPanelView.swift`, в `body`, между блоком «Пока тебя не было» и `Divider()` перед переключателями, добавить:

```swift
            Divider()
            SkinPickerView(appState: appState)
```

То есть порядок в `VStack` становится: заголовок → сессии → «Пока тебя не было» → **разделитель + облики** → разделитель + тумблеры.

- [ ] **Step 3: Проверить сборку и тесты**

Run: `swift build && swift test`
Expected: сборка чистая, все тесты зелёные.

- [ ] **Step 4: Проверить панель рендером**

Стенд из Задачи 6 (шаг 6) не годится: `DetailsPanelView` тянет `AppState` со всей его начинкой. Проверять запуском собранного приложения — Задача 8, шаг 4. Здесь достаточно убедиться, что панель компилируется и что ширина сетки помещается: 5 × 34 pt + 4 × 8 pt = 202 pt при внутренней ширине панели 290 − 2 × 14 = 262 pt. Записать этот расчёт комментарием рядом с `columns` уже сделано.

- [ ] **Step 5: Commit**

```bash
git add Sources/CodeCatApp/SkinPickerView.swift Sources/CodeCatApp/DetailsPanelView.swift
git commit -m "feat: переключатель обликов в панели деталей"
```

---

## Задача 8: Сборка приложения и документация

**Files:**
- Modify: `Makefile`
- Modify: `README.md`

**Interfaces:**
- Consumes: всё предыдущее.
- Produces: `make app`, который кладёт ресурсный бандл в `.app` и падает, если ассетов там нет.

Почему это отдельная задача с проверкой, а не строчка в `Makefile`: в этом проекте класс дефекта «работает под `swift run`, молча ломается в собранном `.app`» ловился уже дважды, и тест по `#filePath` из Задачи 4 его не ловит — он смотрит на исходники.

- [ ] **Step 1: Дописать цель `app`**

В `Makefile`, в цель `app`, после строки `cp scripts/install-lid-mode.sh ...` и до `codesign`, добавить:

```makefile
	cp -R .build/release/CodeCat_CodeCatApp.bundle $(APP)/Contents/Resources/
	@test -d "$(APP)/Contents/Resources/CodeCat_CodeCatApp.bundle/Contents/Resources/Skins" \
		|| (echo "ОШИБКА: ассеты обликов не попали в бандл"; exit 1)
	@test -f "$(APP)/Contents/Resources/CodeCat_CodeCatApp.bundle/Contents/Resources/Skins/mxmaze/16x16-Brown.png" \
		|| (echo "ОШИБКА: в бандле нет листов обликов"; exit 1)
	@test -f "$(APP)/Contents/Resources/CodeCat_CodeCatApp.bundle/Contents/Resources/Skins/elthen/Cat Sprite Sheet.png" \
		|| (echo "ОШИБКА: в бандле нет листа Elthen"; exit 1)
	@test -f "$(APP)/Contents/Resources/CodeCat_CodeCatApp.bundle/Contents/Resources/Skins/luizmelo/Cat-1/Cat-1-Meow.png" \
		|| (echo "ОШИБКА: в бандле нет листов LuizMelo"; exit 1)
```

Точный путь внутри ресурсного бандла проверить командой ниже, а не угадывать: SwiftPM на macOS кладёт ресурсы в `Contents/Resources/` внутри бандла, но если структура окажется плоской — поправить пути в `Makefile` под то, что есть на самом деле.

- [ ] **Step 2: Собрать и посмотреть, что внутри**

```bash
make app
find dist/CodeCat.app -name "*.bundle" -o -name "Skins" -maxdepth 6 | head
find dist/CodeCat.app -name "16x16-Brown.png"
```

Expected: `make app` завершается словами «Готово», и `find` находит `16x16-Brown.png` внутри `dist/CodeCat.app`. Если пути в проверках не совпали с реальными — исправить проверки и пересобрать.

- [ ] **Step 3: Проверить, что проверка работает как проверка**

```bash
rm -rf dist/CodeCat.app/Contents/Resources/CodeCat_CodeCatApp.bundle
make app
```

Ожидание: `make app` пересобирает бандл и проходит. Затем убедиться, что проверка вообще способна упасть:

```bash
make app && rm -rf dist/CodeCat.app/Contents/Resources/CodeCat_CodeCatApp.bundle/Contents/Resources/Skins/mxmaze && \
  test -f "dist/CodeCat.app/Contents/Resources/CodeCat_CodeCatApp.bundle/Contents/Resources/Skins/mxmaze/16x16-Brown.png" \
  || echo "проверка сработала бы"
```

Expected: печатается «проверка сработала бы».

- [ ] **Step 4: Установить и посмотреть глазами**

```bash
make app && pkill -x CodeCat; rm -rf /Applications/CodeCat.app && cp -R dist/CodeCat.app /Applications/ && open -a /Applications/CodeCat.app
```

Проверить:

1. Кот появился (нарисованный — облик по умолчанию не поменялся сам).
2. Клик по коту открывает панель, в ней сетка из девяти превью в два ряда, все девять анимированы, горизонтальной прокрутки нет.
3. Клик по превью меняет кота на экране немедленно, панель не закрывается, у выбранного появляется рамка.
4. Перезапуск приложения сохраняет выбранный облик.
5. «Об ассетах» раскрывается, в ней три набора, у mxmaze видно «CC BY 4.0».
6. Перетаскивание кота работает у спрайтового облика так же, как у нарисованного.

- [ ] **Step 5: Обновить README**

В `README.md` добавить раздел «Облики котика» после раздела «Переход к сессии»:

```markdown
## Облики котика

Кроме нарисованного кота доступны восемь спрайтовых обликов из трёх бесплатных
наборов: шесть котов LuizMelo (CC0), кот Elthen (условия автора) и котёнок mxmaze
(CC BY 4.0, атрибуция обязательна). Переключаются в панели деталей сеткой живых
превью; там же строка «Об ассетах» с авторами, лицензиями и ссылками. Выбор
хранится в `UserDefaults` (`mascotSkin`), по умолчанию — нарисованный кот.

В наборах есть не все пять состояний, которые показывает маскот. В таких случаях
берётся ближайшая анимация **того же** набора — стили не смешиваются никогда, а
смысловое различие несёт бейдж. Подробности и таблицы соответствий:
`docs/superpowers/specs/2026-08-30-mascot-skins-design.md`.

Ассеты лежат в `Sources/CodeCatApp/Skins/` вместе с `CREDITS.md` и оригинальными
файлами лицензий; `fetch-assets.sh` воспроизводит скачивание с itch.io.
```

В ручной чек-лист README добавить пункты:

```markdown
13. Открыть панель → сетка обликов в два ряда, все девять превью анимированы,
    горизонтальной прокрутки нет.
14. Кликнуть по превью → кот на экране меняется сразу, панель не закрывается,
    у выбранного облика рамка.
15. Перезапустить приложение → выбранный облик сохранился.
16. Раскрыть «Об ассетах» → три набора, у mxmaze видно «CC BY 4.0» и имя автора.
```

- [ ] **Step 6: Commit**

```bash
git add Makefile README.md
git commit -m "build: ассеты обликов в бандле приложения + документация"
```

---

## Самопроверка плана

**Покрытие спека.** Модель — Задачи 1–2; правило масштаба и кадрирования — Задачи 3 и 5; ресурсы и `Package.swift` — Задача 4; загрузка листов — Задача 5; отрисовка, бейдж, выбор вида — Задача 6; интерфейс переключения и credits — Задача 7; `make app` и документация — Задача 8. Обработка ошибок: неизвестный id — Задача 2 (`skin(withID:)` + тест), неудачная загрузка — Задача 6 (`reportSkinLoadFailure` + откат в `MascotView`), кадр вне листа — Задача 4 (тест согласованности). Тестирование: все пункты списка из спека разложены по Задачам 1–4.

**Что план сознательно оставляет исполнителю.** Точные пути внутри ресурсного бандла в Задаче 8 (шаг 1) — их надо посмотреть, а не угадать; рамки котов `Cat-2`…`Cat-6` в Задаче 5 (шаг 3) могут отличаться от `Cat-1` на пиксель.

**Предупреждение из опыта проекта.** Код-примеры в планах здесь регулярно оказывались неверны. Не транскрибируй их дословно — проверяй компилятором и глазами. В частности: путь `Bundle.module.url(forResource:)` в Задаче 5 надо подтвердить запуском, а не верой.
