# Остров: маскот в вырезе MacBook — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Добавить второй режим отображения маскота — чёрную плашку вокруг физического выреза экрана: кот в левом крыле, счётчик сессий в правом, меню по наведению и по клику; плавающий кот остаётся первым режимом и не меняется.

**Architecture:** Геометрия выреза и раскладка живут в `CodeCatCore/IslandLayout.swift` — чистые функции над `CGRect`, покрытые юнит-тестами. Новый `IslandController` рисует остров и его меню; существующий `OverlayController` не трогается. Оба реализуют протокол `MascotPresenting`, `AppDelegate` держит активный и пересоздаёт при смене режима. Содержимое меню — общие SwiftUI-компоненты, у которых фон стал параметром: материал для плавающего кота, чистый чёрный для острова.

**Tech Stack:** Swift 5.9, SwiftPM, macOS 14+, AppKit (`NSPanel`, `NSScreen`, `NSTrackingArea`), SwiftUI, XCTest.

**Spec:** `docs/superpowers/specs/2026-08-31-mascot-island-design.md`

## Global Constraints

- Комментарии и строки интерфейса — **по-русски**, как во всём проекте. Имена типов и функций — по-английски.
- Плавающий режим обязан после каждой задачи выглядеть и вести себя **ровно как до неё**. Любое изменение общего кода делается через параметр со значением по умолчанию, а не переписыванием.
- Пиксель-арт рисуется только с **целочисленным** увеличением и `.interpolation(.none)`. Дробный масштаб — дефект.
- Всё, что можно посчитать без AppKit, живёт в `CodeCatCore` и покрывается тестами. `Tests/CodeCatCoreTests` — единственный тестовый таргет; таргет приложения тестами не покрыт, поэтому вся проверка UI — сборка плюс ручной чеклист.
- Измеренные на целевой машине константы, от которых нельзя отступать: высота строки меню с вырезом `safeAreaInsets.top = 32 pt`; вырез x ∈ [771, 956], 185 pt; уровни окон — строка меню 24, статус-иконки 25, раскрытые меню 101, **остров 26**.
- Тесты гоняются `swift test`, сборка — `swift build`, бандл — `make app`.
- Коммит после каждой задачи, сообщение по-русски.

---

### Task 1: `IslandLayout` — геометрия острова

**Files:**
- Create: `Sources/CodeCatCore/IslandLayout.swift`
- Test: `Tests/CodeCatCoreTests/IslandLayoutTests.swift`

**Interfaces:**
- Consumes: ничего.
- Produces: `IslandLayout.wingPadding: CGFloat`, `IslandLayout.counterWingWidth: CGFloat`, `IslandLayout.cornerRadius: CGFloat`, `IslandLayout.hasNotch(safeAreaTop:) -> Bool`, `IslandLayout.notchRect(auxLeft:auxRight:) -> CGRect?`, `IslandLayout.wingWidth(spriteWidth:) -> CGFloat`, `IslandLayout.islandFrame(notch:leftWingWidth:rightWingWidth:) -> CGRect`, `IslandLayout.menuFrame(island:size:screenFrame:edgeInset:) -> CGRect`.

- [ ] **Step 1: Написать падающие тесты**

Создай `Tests/CodeCatCoreTests/IslandLayoutTests.swift`:

```swift
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

    /// Меню выше экрана не должно уезжать под нижнюю границу.
    func testMenuNeverGoesBelowTheScreen() {
        let island = CGRect(x: 701, y: 1085, width: 289, height: 32)
        let menu = IslandLayout.menuFrame(island: island,
                                          size: CGSize(width: 290, height: 4000),
                                          screenFrame: screen)
        XCTAssertGreaterThanOrEqual(menu.minY, screen.minY)
    }
}
```

- [ ] **Step 2: Убедиться, что тесты падают**

Run: `swift test --filter IslandLayoutTests`
Expected: FAIL — `cannot find 'IslandLayout' in scope`.

- [ ] **Step 3: Написать `IslandLayout`**

Создай `Sources/CodeCatCore/IslandLayout.swift`:

```swift
import CoreGraphics

/// Геометрия «острова» — чёрной плашки, накрывающей физический вырез экрана и
/// заходящей крыльями влево и вправо.
///
/// Всё считается из двух вспомогательных областей, которые macOS сообщает для
/// экрана с вырезом (`NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea`):
/// это участки строки меню слева и справа от выреза. Сам вырез — дырка между
/// ними, и другого способа узнать его ширину система не даёт.
///
/// Здесь нет прямоугольников содержимого (кота, счётчика): `IslandView` кладёт
/// три известные ширины — левое крыло, вырез, правое крыло — обычным `HStack`,
/// и заводить ради этого вторую систему координат незачем.
public enum IslandLayout {

    /// Отступ от спрайта до края крыла с каждой стороны. Крылья физически
    /// перекрывают строку меню (слева меню приложения, справа чужие статус-иконки),
    /// поэтому они делаются ровно по спрайту, а не «пошире на глаз».
    public static let wingPadding: CGFloat = 8

    /// Правое крыло не зависит от облика: там либо число сессий, либо точка.
    public static let counterWingWidth: CGFloat = 34

    /// Скругление нижних углов острова и меню. Верхние углы острова прямые —
    /// они упираются в кромку экрана.
    public static let cornerRadius: CGFloat = 10

    /// Есть ли у экрана вырез. На экране без выреза верхний safe-area-инсет равен
    /// нулю; на встроенном экране MacBook Pro он равен высоте строки меню (32 pt).
    public static func hasNotch(safeAreaTop: CGFloat) -> Bool { safeAreaTop > 0 }

    /// Вырез — промежуток между вспомогательными областями. `nil`, если система их
    /// не сообщила (экран без выреза) или если между ними нет положительной ширины.
    public static func notchRect(auxLeft: CGRect?, auxRight: CGRect?) -> CGRect? {
        guard let auxLeft, let auxRight else { return nil }
        let width = auxRight.minX - auxLeft.maxX
        guard width > 0, auxLeft.height > 0 else { return nil }
        return CGRect(x: auxLeft.maxX, y: auxLeft.minY, width: width, height: auxLeft.height)
    }

    /// Ширина крыла под спрайт: сам спрайт плюс `wingPadding` с каждой стороны.
    public static func wingWidth(spriteWidth: CGFloat) -> CGFloat {
        spriteWidth + 2 * wingPadding
    }

    /// Вся плашка: вырез плюс два крыла. Высота равна высоте выреза — остров не
    /// выходит за строку меню.
    public static func islandFrame(notch: CGRect,
                                   leftWingWidth: CGFloat,
                                   rightWingWidth: CGFloat) -> CGRect {
        CGRect(x: notch.minX - leftWingWidth,
               y: notch.minY,
               width: leftWingWidth + notch.width + rightWingWidth,
               height: notch.height)
    }

    /// Выпадающее меню: верхняя кромка вплотную к низу острова (щель между чёрным
    /// меню и чёрным островом сразу выдала бы, что это два разных окна), центр по
    /// острову, всё подрезано по краям экрана.
    public static func menuFrame(island: CGRect,
                                 size: CGSize,
                                 screenFrame: CGRect,
                                 edgeInset: CGFloat = 8) -> CGRect {
        let lowerBound = screenFrame.minX + edgeInset
        let upperBound = screenFrame.maxX - size.width - edgeInset
        // Меню шире экрана: подрезка сверху и снизу противоречат друг другу,
        // поэтому прижимаем к левому краю, а не считаем min от max.
        let x = upperBound >= lowerBound
            ? min(max(island.midX - size.width / 2, lowerBound), upperBound)
            : lowerBound
        let y = max(screenFrame.minY, island.minY - size.height)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}
```

- [ ] **Step 4: Убедиться, что тесты проходят**

Run: `swift test --filter IslandLayoutTests`
Expected: PASS, 8 тестов.

- [ ] **Step 5: Коммит**

```bash
git add Sources/CodeCatCore/IslandLayout.swift Tests/CodeCatCoreTests/IslandLayoutTests.swift
git commit -m "feat: геометрия острова вокруг выреза, покрытая тестами"
```

---

### Task 2: Масштаб спрайта под строку меню

**Files:**
- Modify: `Sources/CodeCatCore/SpriteScale.swift`
- Modify: `Tests/CodeCatCoreTests/SpriteScaleTests.swift`
- Modify: `Sources/CodeCatApp/SpriteSheetStore.swift:19-21`
- Modify: `Sources/CodeCatApp/SpriteMascotView.swift`

**Interfaces:**
- Consumes: ничего из Task 1.
- Produces: `SpriteScale.islandTargetHeight: Int` (32), `SpriteScale.islandMaxWidth: Int` (60), `SpriteScale.factor(boundsWidth:boundsHeight:targetHeight:maxWidth:) -> Int` с прежними значениями по умолчанию; `LoadedSkin.drawingSize(targetHeight:maxWidth:) -> CGSize`; `SpriteMascotView` с новыми необязательными параметрами `drawingSize: CGSize?` и `canvasSize: CGFloat?`.

- [ ] **Step 1: Дописать падающие тесты**

Добавь в конец `final class SpriteScaleTests` в `Tests/CodeCatCoreTests/SpriteScaleTests.swift`:

```swift
    // MARK: - Островная нормировка (строка меню 32 pt)

    /// Все облики в строке меню обязаны получить один и тот же целочисленный
    /// множитель, иначе коты разъедутся по высоте вдвое, как это уже было на
    /// канве маскота. Рамки — те же, что в тесте выше: шесть котов LuizMelo не
    /// делят одну рамку (cat-4 — 28x16, cat-5 — 27x16).
    func testEverySkinLandsOnTimesTwoInTheMenuBar() {
        let bounds = [(27, 14), (28, 16), (27, 16), (18, 12), (16, 16)]
        for (w, h) in bounds {
            XCTAssertEqual(SpriteScale.factor(boundsWidth: w, boundsHeight: h,
                                              targetHeight: SpriteScale.islandTargetHeight,
                                              maxWidth: SpriteScale.islandMaxWidth),
                           2, "\(w)x\(h)")
        }
    }

    /// Прямая причина, по которой islandTargetHeight равен именно 32: на 30 pt
    /// mxmaze (16x16) падает до x1 и становится вдвое мельче остальных.
    func testALowerTargetWouldHalveTheSquareSkin() {
        XCTAssertEqual(SpriteScale.factor(boundsWidth: 16, boundsHeight: 16,
                                          targetHeight: 30, maxWidth: 60), 1)
    }

    /// Ни один облик не должен вылезти за отведённую ширину крыла.
    func testIslandWidthsStayWithinTheCap() {
        let bounds = [(27, 14), (28, 16), (27, 16), (18, 12), (16, 16)]
        for (w, h) in bounds {
            let s = SpriteScale.factor(boundsWidth: w, boundsHeight: h,
                                       targetHeight: SpriteScale.islandTargetHeight,
                                       maxWidth: SpriteScale.islandMaxWidth)
            XCTAssertLessThanOrEqual(w * s, SpriteScale.islandMaxWidth, "\(w)x\(h)")
            XCTAssertLessThanOrEqual(h * s, SpriteScale.islandTargetHeight, "\(w)x\(h)")
        }
    }

    /// Плавающий кот не имеет права поменяться ни на пиксель: вызов без новых
    /// параметров обязан давать ровно то же, что и раньше.
    func testDefaultArgumentsReproduceTheFloatingMascot() {
        XCTAssertEqual(SpriteScale.factor(boundsWidth: 27, boundsHeight: 14), 4)
        XCTAssertEqual(SpriteScale.factor(boundsWidth: 18, boundsHeight: 12), 5)
        XCTAssertEqual(SpriteScale.factor(boundsWidth: 16, boundsHeight: 16), 4)
        XCTAssertEqual(SpriteScale.factor(boundsWidth: 27, boundsHeight: 14,
                                          targetHeight: SpriteScale.targetHeight,
                                          maxWidth: SpriteScale.maxWidth), 4)
    }
```

- [ ] **Step 2: Убедиться, что тесты падают**

Run: `swift test --filter SpriteScaleTests`
Expected: FAIL — `extra arguments 'targetHeight', 'maxWidth' in call` и `type 'SpriteScale' has no member 'islandTargetHeight'`.

- [ ] **Step 3: Параметризовать `SpriteScale`**

В `Sources/CodeCatCore/SpriteScale.swift` добавь две константы рядом с существующими и замени `factor`:

```swift
    /// Высота, к которой нормируется облик в строке меню на экране с вырезом
    /// (`safeAreaInsets.top` = 32 pt). Меньше нельзя: на 30 pt квадратный облик
    /// mxmaze (16x16) падает до x1 — см. `SpriteScaleTests`.
    public static let islandTargetHeight = 32

    /// Предел ширины спрайта в крыле острова. Крыло перекрывает строку меню,
    /// поэтому оно не должно разрастаться ради широких четвероногих котов.
    public static let islandMaxWidth = 60

    /// Integer magnification for a skin whose union bounding box is
    /// `boundsWidth` x `boundsHeight` pixels. Never returns less than 1: a sprite
    /// too large to fit is drawn at 1x rather than vanishing.
    ///
    /// Нормировка задаётся параметрами, потому что мест теперь два: канва
    /// плавающего маскота (значения по умолчанию — 64/120) и строка меню
    /// (`islandTargetHeight`/`islandMaxWidth`). Значения по умолчанию обязаны
    /// оставаться прежними: от них зависит вид плавающего кота.
    public static func factor(boundsWidth: Int,
                              boundsHeight: Int,
                              targetHeight: Int = SpriteScale.targetHeight,
                              maxWidth: Int = SpriteScale.maxWidth) -> Int {
        guard boundsWidth > 0, boundsHeight > 0 else { return 1 }
        return max(1, min(targetHeight / boundsHeight, maxWidth / boundsWidth))
    }
```

Старую версию `factor` удали — новая её полностью заменяет.

- [ ] **Step 4: Убедиться, что тесты проходят**

Run: `swift test --filter SpriteScaleTests`
Expected: PASS. Прежние тесты в этом файле обязаны пройти без правок — это и есть проверка, что плавающий кот не поехал.

- [ ] **Step 5: Открыть размер отрисовки у `LoadedSkin`**

В `Sources/CodeCatApp/SpriteSheetStore.swift` замени свойство `drawingSize` (строки 19-21) на:

```swift
    /// On-screen size of the drawing, in points.
    var drawingSize: CGSize {
        CGSize(width: bounds.width * CGFloat(scale), height: bounds.height * CGFloat(scale))
    }

    /// Размер отрисовки при другой нормировке — для острова, где строка меню
    /// всего 32 pt. `scale` посчитан при загрузке под канву плавающего маскота,
    /// поэтому здесь множитель пересчитывается из той же измеренной рамки.
    func drawingSize(targetHeight: Int, maxWidth: Int) -> CGSize {
        let factor = SpriteScale.factor(boundsWidth: Int(bounds.width),
                                        boundsHeight: Int(bounds.height),
                                        targetHeight: targetHeight,
                                        maxWidth: maxWidth)
        return CGSize(width: bounds.width * CGFloat(factor),
                      height: bounds.height * CGFloat(factor))
    }
```

- [ ] **Step 6: Открыть размеры у `SpriteMascotView`**

В `Sources/CodeCatApp/SpriteMascotView.swift` добавь два свойства и используй их. Меняются ровно три места; остальное тело не трогать:

```swift
    /// Previews in the details panel cap this: nine animations run at once there.
    var maxFPS: Double = 8
    var showsBadge: Bool = true
    /// Размер спрайта на экране. Не задан — берётся размер из `LoadedSkin`,
    /// то есть нормировка плавающего маскота.
    var drawingSize: CGSize?
    /// Размер холста вокруг спрайта. Не задан — канва плавающего маскота.
    var canvasSize: CGSize?
```

В `body` замени модификатор кадра:

```swift
        .frame(width: canvasSize?.width ?? MascotLayout.canvasSize,
               height: canvasSize?.height ?? MascotLayout.canvasSize)
```

и в `frameImage(at:in:)` — размер картинки:

```swift
            let size = drawingSize ?? loaded.drawingSize
            Image(decorative: cgImage, scale: 1)
                .interpolation(.none)
                .antialiased(false)
                .resizable()
                .frame(width: size.width, height: size.height)
```

- [ ] **Step 7: Собрать и убедиться, что ничего не сломано**

Run: `swift build && swift test`
Expected: сборка без ошибок, все тесты проходят.

- [ ] **Step 8: Коммит**

```bash
git add Sources/CodeCatCore/SpriteScale.swift Tests/CodeCatCoreTests/SpriteScaleTests.swift Sources/CodeCatApp/SpriteSheetStore.swift Sources/CodeCatApp/SpriteMascotView.swift
git commit -m "feat: масштаб спрайта параметризован — облики влезают в строку меню 32pt"
```

---

### Task 3: Режим отображения в модели и настройках

**Files:**
- Create: `Sources/CodeCatCore/MascotDisplayMode.swift`
- Test: `Tests/CodeCatCoreTests/MascotDisplayModeTests.swift`
- Modify: `Sources/CodeCatApp/AppState.swift:23-60` (блок `@Published`) и `AppState.init` (регистрация значений по умолчанию)

**Interfaces:**
- Consumes: ничего.
- Produces: `MascotDisplayMode` (`.floating`, `.island`) c `rawValue`, `title`, `MascotDisplayMode.default`, `MascotDisplayMode.mode(withID:)`; `AppState.displayMode: MascotDisplayMode`, `AppState.islandHidesWhenIdle: Bool`, `AppState.islandShouldHideNow: Bool`.

- [ ] **Step 1: Написать падающие тесты**

Создай `Tests/CodeCatCoreTests/MascotDisplayModeTests.swift`:

```swift
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
```

- [ ] **Step 2: Убедиться, что тесты падают**

Run: `swift test --filter MascotDisplayModeTests`
Expected: FAIL — `cannot find 'MascotDisplayMode' in scope`.

- [ ] **Step 3: Написать тип**

Создай `Sources/CodeCatCore/MascotDisplayMode.swift`:

```swift
import Foundation

/// Способ показывать маскота на экране. Режимы взаимоисключающие: одновременно
/// на экране всегда ровно один.
public enum MascotDisplayMode: String, CaseIterable, Sendable {
    /// Плавающее окно, которое пользователь таскает мышью. Поведение с MVP.
    case floating
    /// Чёрная плашка вокруг физического выреза встроенного экрана.
    case island

    /// Установка новой версии не должна менять вид сама по себе.
    public static let `default` = MascotDisplayMode.floating

    /// Читает значение из настроек. Всё, чего не знаем, — режим по умолчанию:
    /// в `UserDefaults` может лежать строка от старой или будущей версии.
    public static func mode(withID id: String?) -> MascotDisplayMode {
        guard let id, let mode = MascotDisplayMode(rawValue: id) else { return .default }
        return mode
    }

    /// Подпись в интерфейсе.
    public var title: String {
        switch self {
        case .floating: return "Кот"
        case .island: return "Остров"
        }
    }
}
```

- [ ] **Step 4: Убедиться, что тесты проходят**

Run: `swift test --filter MascotDisplayModeTests`
Expected: PASS, 4 теста.

- [ ] **Step 5: Завести настройки в `AppState`**

В `Sources/CodeCatApp/AppState.swift` добавь два `@Published` рядом с `skinID` (после его объявления):

```swift
    /// Как показывать маскота. Персистится, чтобы выбор пережил перезапуск;
    /// читается через `MascotDisplayMode.mode(withID:)`, который откатывает
    /// незнакомую строку к режиму по умолчанию.
    @Published var displayMode: MascotDisplayMode {
        didSet { UserDefaults.standard.set(displayMode.rawValue, forKey: "mascotDisplayMode") }
    }

    /// Прятать остров, когда сессий нет вовсе. По умолчанию выключено: остров
    /// стоит на одном месте, и на него всегда можно навести мышь.
    @Published var islandHidesWhenIdle: Bool {
        didSet { UserDefaults.standard.set(islandHidesWhenIdle, forKey: "islandHidesWhenIdle") }
    }

    /// Должен ли остров прямо сейчас быть скрыт по настройке «прятать в покое».
    var islandShouldHideNow: Bool {
        guard islandHidesWhenIdle else { return false }
        if case .sleeping = store.aggregate { return true }
        return false
    }
```

В `init()` добавь ключи в регистрацию значений по умолчанию:

```swift
        defaults.register(defaults: [
            "keepAwake": true, "lidMode": false, "sounds": false, "showMascot": true,
            "mascotSkin": MascotSkins.default.id,
            "mascotDisplayMode": MascotDisplayMode.default.rawValue,
            "islandHidesWhenIdle": false,
        ])
```

и присвой значения рядом с остальными (до `skinID`, порядок внутри `init` роли не играет, но все хранимые свойства обязаны получить значение до первого чтения `self`):

```swift
        displayMode = MascotDisplayMode.mode(withID: defaults.string(forKey: "mascotDisplayMode"))
        islandHidesWhenIdle = defaults.bool(forKey: "islandHidesWhenIdle")
```

- [ ] **Step 6: Собрать и прогнать всё**

Run: `swift build && swift test`
Expected: сборка и тесты зелёные.

- [ ] **Step 7: Коммит**

```bash
git add Sources/CodeCatCore/MascotDisplayMode.swift Tests/CodeCatCoreTests/MascotDisplayModeTests.swift Sources/CodeCatApp/AppState.swift
git commit -m "feat: режим отображения маскота в модели и настройках"
```

---

### Task 4: Пустой остров и переключение режимов

Самая рискованная задача: уровень окна, попадание в вырез, жизненный цикл двух контроллеров. Поэтому в ней остров ещё **пустой** — чёрная плашка без кота и счётчика. Её единственная цель: убедиться глазами, что плашка ложится ровно в вырез и что режимы переключаются в обе стороны.

**Files:**
- Create: `Sources/CodeCatApp/MascotPresenting.swift`
- Create: `Sources/CodeCatApp/IslandController.swift`
- Modify: `Sources/CodeCatApp/OverlayPanel.swift` (конформанс `OverlayController` к `MascotPresenting`)
- Modify: `Sources/CodeCatApp/AppDelegate.swift`

**Interfaces:**
- Consumes: `IslandLayout` (Task 1), `MascotDisplayMode`, `AppState.displayMode` (Task 3).
- Produces: `protocol MascotPresenting { func setVisible(_ visible: Bool) }`; `IslandController(appState:)`; `IslandController.islandLevel: NSWindow.Level`.

- [ ] **Step 1: Завести протокол**

Создай `Sources/CodeCatApp/MascotPresenting.swift`:

```swift
import Foundation

/// Один способ показывать маскота. Реализаций две — плавающее окно
/// (`OverlayController`) и остров в вырезе (`IslandController`), — и на экране
/// одновременно живёт ровно одна: `AppDelegate` уничтожает предыдущую при смене
/// режима.
///
/// Протокол намеренно узкий. Всё остальное — позиция, наведение, меню — у режимов
/// разное настолько, что общий интерфейс поверх этого был бы выдумкой.
protocol MascotPresenting: AnyObject {
    /// Показать или скрыть весь режим целиком, вместе с его меню.
    func setVisible(_ visible: Bool)
}
```

- [ ] **Step 2: Подписать существующий контроллер под протокол**

В `Sources/CodeCatApp/OverlayPanel.swift` замени объявление класса:

```swift
final class OverlayController: NSObject, NSWindowDelegate, MascotPresenting {
```

Метод `setVisible(_:)` там уже есть — тело не трогать.

- [ ] **Step 3: Написать контроллер острова**

Создай `Sources/CodeCatApp/IslandController.swift`:

```swift
import AppKit
import SwiftUI
import Combine
import CodeCatCore

/// Остров: чёрная плашка вокруг физического выреза встроенного экрана.
///
/// Работает только там, где вырез есть. Внешний монитор, закрытая крышка и Mac
/// без выреза — это `geometry() == nil`, и тогда контроллер не показывает ничего:
/// управление остаётся в иконке статус-бара, откуда можно вернуться к плавающему
/// коту.
final class IslandController: NSObject, MascotPresenting {

    /// Строка меню лежит на уровне 24, чужие статус-иконки — на 25, раскрытые
    /// системные меню — на 101 (замерено `CGWindowLevelForKey`). Остров кладётся
    /// на 26: выше строки меню и иконок, но ниже раскрытых меню, поэтому они
    /// рисуются поверх него и драки за клики не возникает.
    static let islandLevel = NSWindow.Level(
        rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)

    private let appState: AppState
    private var islandPanel: OverlayPanel?
    private var cancellables: Set<AnyCancellable> = []
    private var isVisible = false

    /// Всё, что нужно знать о геометрии в текущий момент. Пересчитывается на
    /// каждое изменение состояния: облик мог смениться, экран — отключиться.
    struct Geometry {
        let screen: NSScreen
        let notch: CGRect
        let island: CGRect
        let leftWingWidth: CGFloat
        let rightWingWidth: CGFloat
        let spriteSize: CGSize
    }

    init(appState: AppState) {
        self.appState = appState
        super.init()

        appState.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.handleStateChange() }
            .store(in: &cancellables)

        setVisible(appState.showMascot)
    }

    deinit {
        // Панель надо увести с экрана явно: контроллер умирает при смене режима,
        // и оставленное видимым окно пережило бы его.
        islandPanel?.orderOut(nil)
    }

    func setVisible(_ visible: Bool) {
        isVisible = visible
        guard visible, let geometry = geometry() else {
            islandPanel?.orderOut(nil)
            return
        }
        let panel = islandPanel ?? makePanel()
        islandPanel = panel
        panel.setFrame(geometry.island, display: true)
        panel.orderFrontRegardless()
    }

    private func handleStateChange() {
        setVisible(appState.showMascot)
    }

    private func makePanel() -> OverlayPanel {
        let panel = OverlayPanel(contentRect: .zero, allowsKey: false)
        panel.level = Self.islandLevel
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.acceptsMouseMovedEvents = true
        // Плашка пока пустая: содержимое приезжает следующей задачей.
        panel.contentView = NSHostingView(rootView:
            RoundedRectangle(cornerRadius: IslandLayout.cornerRadius)
                .fill(Color.black)
                .ignoresSafeArea())
        return panel
    }

    /// Экран с вырезом и вся производная геометрия. `nil` — острову негде жить.
    private func geometry() -> Geometry? {
        guard let screen = NSScreen.screens.first(where: {
            IslandLayout.hasNotch(safeAreaTop: $0.safeAreaInsets.top)
        }), let notch = IslandLayout.notchRect(auxLeft: screen.auxiliaryTopLeftArea,
                                               auxRight: screen.auxiliaryTopRightArea)
        else { return nil }

        let spriteSize = SpriteSheetStore.shared.load(appState.skin)?
            .drawingSize(targetHeight: SpriteScale.islandTargetHeight,
                         maxWidth: SpriteScale.islandMaxWidth)
            ?? CGSize(width: 24, height: 24)
        let left = IslandLayout.wingWidth(spriteWidth: spriteSize.width)
        let right = IslandLayout.counterWingWidth
        return Geometry(screen: screen,
                        notch: notch,
                        island: IslandLayout.islandFrame(notch: notch,
                                                         leftWingWidth: left,
                                                         rightWingWidth: right),
                        leftWingWidth: left,
                        rightWingWidth: right,
                        spriteSize: spriteSize)
    }
}
```

- [ ] **Step 4: Переключать режимы в `AppDelegate`**

В `Sources/CodeCatApp/AppDelegate.swift` замени свойство `overlay` на пару и добавь синхронизацию:

```swift
    private var presenter: MascotPresenting?
    private var presentedMode: MascotDisplayMode?
```

В `applicationDidFinishLaunching` замени `overlay = OverlayController(appState: appState)` на `syncPresenter()`, а в подписке на `appState.objectWillChange` вызывай обе синхронизации:

```swift
            .sink { [weak self] _ in
                self?.updateStatusIcon()
                self?.syncPresenter()
            }
```

Добавь метод:

```swift
    /// Держит на экране ровно один режим. Смена режима — это уничтожение старого
    /// контроллера и создание нового: у них разные окна, разная геометрия и разная
    /// модель ввода, и жить одновременно им незачем. Старый обязательно уводится с
    /// экрана до обнуления ссылки — иначе его окно осталось бы висеть.
    private func syncPresenter() {
        guard presentedMode != appState.displayMode else { return }
        presenter?.setVisible(false)
        presenter = nil
        presentedMode = appState.displayMode
        switch appState.displayMode {
        case .floating: presenter = OverlayController(appState: appState)
        case .island: presenter = IslandController(appState: appState)
        }
    }
```

- [ ] **Step 5: Пункты переключения в меню статус-бара**

В `buildMenu()` перед `menu.addItem(toggle("Не давать маку спать", ...))` добавь:

```swift
        for mode in MascotDisplayMode.allCases {
            let item = NSMenuItem(title: "Вид: \(mode.title)",
                                  action: #selector(selectDisplayMode(_:)), keyEquivalent: "")
            item.state = (appState.displayMode == mode) ? .on : .off
            item.representedObject = mode.rawValue
            menu.addItem(item)
        }
        menu.addItem(.separator())
```

и обработчик рядом с остальными `@objc`:

```swift
    /// Переключение вида живёт и здесь, а не только в панели: если остров окажется
    /// негде показать (встроенный экран отключён), маскота не будет видно вовсе, и
    /// вернуться к плавающему коту надо откуда-то ещё.
    @objc private func selectDisplayMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        appState.displayMode = MascotDisplayMode.mode(withID: raw)
    }
```

- [ ] **Step 6: Собрать и посмотреть глазами**

```bash
swift build && make app && open dist/CodeCat.app
```

Ожидаемое: в меню статус-бара два пункта «Вид», галочка на «Кот». Переключаешь на «Остров» — плавающий кот исчезает, вокруг выреза появляется чёрная плашка высотой ровно со строку меню, со скруглёнными нижними углами; вырез с ней сливается. Переключаешь обратно — кот возвращается на своё сохранённое место, плашка исчезает без остатка.

- [ ] **Step 7: Коммит**

```bash
git add Sources/CodeCatApp/MascotPresenting.swift Sources/CodeCatApp/IslandController.swift Sources/CodeCatApp/OverlayPanel.swift Sources/CodeCatApp/AppDelegate.swift
git commit -m "feat: пустой остров в вырезе и переключение режимов отображения"
```

---

### Task 5: Кот и счётчик в крыльях

**Files:**
- Create: `Sources/CodeCatApp/IslandView.swift`
- Modify: `Sources/CodeCatApp/IslandController.swift` (подставить содержимое вместо заглушки)

**Interfaces:**
- Consumes: `IslandController.Geometry` (Task 4), `SpriteMascotView(drawingSize:canvasSize:showsBadge:)` (Task 2).
- Produces: `IslandView(appState:notchWidth:leftWingWidth:rightWingWidth:spriteSize:height:)`.

- [ ] **Step 1: Написать вид**

Создай `Sources/CodeCatApp/IslandView.swift`:

```swift
import SwiftUI
import CodeCatCore

/// Содержимое острова: кот в левом крыле, счётчик в правом, между ними — дырка
/// под физический вырез.
///
/// Раскладка — `HStack` по трём известным ширинам, без всякой геометрии в самом
/// виде: где эти ширины берутся, знает `IslandController`, а считает их
/// `IslandLayout`.
struct IslandView: View {
    @ObservedObject var appState: AppState
    let notchWidth: CGFloat
    let leftWingWidth: CGFloat
    let rightWingWidth: CGFloat
    let spriteSize: CGSize
    let height: CGFloat

    private var isWaiting: Bool {
        if case .waiting = appState.store.aggregate { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 0) {
            cat
                .frame(width: leftWingWidth, height: height)
            // Физический вырез: сюда ничего не кладём, там дырка в матрице.
            Color.clear
                .frame(width: notchWidth, height: height)
            counter
                .frame(width: rightWingWidth, height: height)
        }
        .frame(height: height)
        .background(Color.black)
        // Верхние углы прямые — они упираются в кромку экрана; скругляются только
        // нижние, чтобы плашка читалась как продолжение выреза.
        .clipShape(BottomRoundedRectangle(radius: IslandLayout.cornerRadius))
    }

    private var cat: some View {
        MascotView(skin: appState.skin,
                   status: appState.store.aggregate,
                   sessionCount: appState.store.badgeCount,
                   drawingSize: spriteSize,
                   canvasSize: CGSize(width: spriteSize.width, height: height),
                   showsBadge: false,
                   onLoadFailure: { [appState] skin in appState.reportSkinLoadFailure(skin) })
    }

    @ViewBuilder
    private var counter: some View {
        let count = appState.store.badgeCount
        if count > 0 {
            // Цвет повторяет логику бейджа плавающего кота: ожидание пользователя —
            // единственное состояние, которое имеет право быть красным.
            Text("\(count)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isWaiting ? Color(red: 1.0, green: 0.35, blue: 0.35) : .white)
        } else {
            // Считать нечего — но остров остаётся на месте, иначе на него нельзя
            // будет навести мышь. Точка вместо числа.
            Circle()
                .fill(Color.white.opacity(0.35))
                .frame(width: 6, height: 6)
        }
    }
}

/// Прямоугольник со скруглением только снизу.
struct BottomRoundedRectangle: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
                          control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius),
                          control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
```

- [ ] **Step 2: Пробросить размеры через `MascotView`**

`IslandView` зовёт `MascotView` с новыми параметрами, которых у него пока нет. В `Sources/CodeCatApp/MascotView.swift` добавь их и передай дальше — `CatView` (аварийная отрисовка) остаётся как есть, у него своя геометрия:

```swift
struct MascotView: View {
    let skin: MascotSkin
    let status: AggregateStatus
    let sessionCount: Int
    /// Размеры для острова. Не заданы — канва и нормировка плавающего маскота.
    var drawingSize: CGSize?
    var canvasSize: CGSize?
    var showsBadge: Bool = true
    /// Called when a sprite skin could not be loaded, so the app can report it.
    var onLoadFailure: (MascotSkin) -> Void = { _ in }
```

и в `content`:

```swift
        if let loaded = SpriteSheetStore.shared.load(skin) {
            SpriteMascotView(loaded: loaded, status: status, sessionCount: sessionCount,
                             showsBadge: showsBadge,
                             drawingSize: drawingSize, canvasSize: canvasSize)
        } else {
            CatView(status: status, sessionCount: sessionCount)
        }
```

Проверь порядок параметров в вызове `SpriteMascotView` по его объявлению (Task 2): в Swift у memberwise-инициализатора структуры порядок аргументов обязан совпадать с порядком свойств.

- [ ] **Step 3: Подставить вид в контроллер**

В `Sources/CodeCatApp/IslandController.swift` замени тело `makePanel()` и добавь обновление содержимого. `setVisible` должен пересоздавать `rootView` при каждом изменении, потому что ширина крыла зависит от облика:

```swift
    private func makePanel() -> OverlayPanel {
        let panel = OverlayPanel(contentRect: .zero, allowsKey: false)
        panel.level = Self.islandLevel
        panel.acceptsMouseMovedEvents = true
        return panel
    }

    private func content(for geometry: Geometry) -> IslandView {
        IslandView(appState: appState,
                   notchWidth: geometry.notch.width,
                   leftWingWidth: geometry.leftWingWidth,
                   rightWingWidth: geometry.rightWingWidth,
                   spriteSize: geometry.spriteSize,
                   height: geometry.island.height)
    }
```

и в `setVisible(_:)` между созданием панели и `setFrame`:

```swift
        if let hosting = panel.contentView as? NSHostingView<IslandView> {
            hosting.rootView = content(for: geometry)
        } else {
            panel.contentView = NSHostingView(rootView: content(for: geometry))
        }
```

- [ ] **Step 4: Собрать и посмотреть глазами**

```bash
swift build && make app && open dist/CodeCat.app
```

Ожидаемое (режим «Остров»): слева от выреза анимированный кот текущего облика, справа — точка (сессий нет) или число. Пиксели квадратные, спрайт не мыльный. Смена облика в панели плавающего режима меняет и кота в острове, крыло меняет ширину под новый спрайт.

- [ ] **Step 5: Коммит**

```bash
git add Sources/CodeCatApp/IslandView.swift Sources/CodeCatApp/MascotView.swift Sources/CodeCatApp/IslandController.swift
git commit -m "feat: кот и счётчик сессий в крыльях острова"
```

---

### Task 6: Распил панели деталей на переиспользуемые части

Чисто механическая задача без нового поведения: содержимое панели должно рисоваться на двух разных фонах. Отдельной задачей — потому что здесь единственный реальный риск регрессии плавающего режима, и ревьюеру надо смотреть именно на это.

**Files:**
- Create: `Sources/CodeCatApp/SessionListView.swift`
- Create: `Sources/CodeCatApp/SettingsSectionView.swift`
- Modify: `Sources/CodeCatApp/DetailsPanelView.swift`

**Interfaces:**
- Consumes: ничего нового.
- Produces: `SessionListView(appState:onJump:)`, `SettingsSectionView(appState:)`.

- [ ] **Step 1: Вынести список сессий**

Создай `Sources/CodeCatApp/SessionListView.swift` и **перенеси туда без единого изменения** из `Sources/CodeCatApp/DetailsPanelView.swift`:

- доккомментарий и объявление `@State private var hovered: String?` (строки 15-35) — комментарий там длиннее самого свойства и описывает обход поведения AppKit с курсором, его нельзя терять;
- метод `sessionRow(_:)` целиком (строки 105-186) со всеми комментариями внутри;
- `color(for:)`, `label(for:)`, `duration(_:)` (строки 188-210);
- модификатор `.onChange(of: hovered)` с комментарием (строки 96-103).

Ничего в перенесённом коде не переписывать: тела методов и комментарии обязаны совпасть с оригиналом посимвольно, иначе смысл задачи (нулевая регрессия) теряется. Оболочка:

```swift
import SwiftUI
import AppKit
import CodeCatCore

/// Список активных сессий плюс сводка «пока тебя не было». Вынесен из
/// `DetailsPanelView`, чтобы то же содержимое рисовалось и в меню острова —
/// на другом фоне, но с той же логикой наведения, курсора и перехода.
///
/// Комментарии про курсор и `hovered` переехали сюда дословно: они описывают
/// нетривиальный обход поведения AppKit, а не стиль кода.
struct SessionListView: View {
    @ObservedObject var appState: AppState
    var onJump: () -> Void = {}

    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if appState.store.ordered.isEmpty {
                Text("Нет активных сессий")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(appState.store.ordered) { session in
                    sessionRow(session)
                }
            }

            if !appState.awayLog.lastSummary.isEmpty {
                Divider()
                Text("Пока тебя не было").font(.system(size: 12, weight: .medium))
                ForEach(appState.awayLog.lastSummary) { entry in
                    Text("• \(entry.text)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: hovered) { _, newValue in
            if newValue != nil {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }

    // сюда переезжают sessionRow(_:), color(for:), label(for:), duration(_:)
    // из DetailsPanelView — дословно, вместе с комментариями
}
```

- [ ] **Step 2: Вынести настройки**

Создай `Sources/CodeCatApp/SettingsSectionView.swift`:

```swift
import SwiftUI
import CodeCatCore

/// Облики и тумблеры. Вынесены из `DetailsPanelView` ради меню острова, где
/// показываются на чёрном фоне и только на полном уровне.
struct SettingsSectionView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SkinPickerView(appState: appState)

            Divider()
            Toggle("Не давать маку спать", isOn: $appState.keepAwakeEnabled)
            Toggle("Режим закрытой крышки", isOn: Binding(
                get: { appState.lidModeEnabled },
                set: { appState.requestLidModeChange(to: $0) }
            ))
            if !LidSleepController.isHelperInstalled {
                Text("Первое включение попросит пароль администратора (разовая настройка).")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Toggle("Звуки", isOn: $appState.soundsEnabled)
            if !appState.hooksInstalled {
                Button("Установить хуки Claude Code") {
                    appState.installHooksIfNeeded()
                }
                .font(.system(size: 11))
            }
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
    }
}
```

- [ ] **Step 3: Свести `DetailsPanelView` к композиции**

Замени тело `Sources/CodeCatApp/DetailsPanelView.swift` целиком на:

```swift
import SwiftUI
import CodeCatCore

/// Панель плавающего режима. Всё содержимое переехало в `SessionListView` и
/// `SettingsSectionView`, здесь остались только заголовок, фон и размер —
/// то, чем эта панель отличается от меню острова.
struct DetailsPanelView: View {
    @ObservedObject var appState: AppState

    /// Called after a jump is started, so the panel can close itself: the user asked
    /// to be somewhere else.
    var onJump: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CodeCat").font(.headline)
            SessionListView(appState: appState, onJump: onJump)
            Divider()
            SettingsSectionView(appState: appState)
        }
        .font(.system(size: 12))
        .padding(14)
        .frame(width: 290, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
```

- [ ] **Step 4: Собрать и сверить плавающий режим глазами**

```bash
swift build && make app && open dist/CodeCat.app
```

Ожидаемое: в режиме «Кот» панель по клику выглядит и ведёт себя **точно как раньше** — тот же размер, те же отступы, тот же материал, работающие тумблеры, живой выбор облика, подсветка строки сессии под курсором и «рука» вместо стрелки. Расхождение здесь — регрессия, а не «мелочь».

- [ ] **Step 5: Коммит**

```bash
git add Sources/CodeCatApp/SessionListView.swift Sources/CodeCatApp/SettingsSectionView.swift Sources/CodeCatApp/DetailsPanelView.swift
git commit -m "refactor: панель деталей распилена на список сессий и настройки"
```

---

### Task 7: Меню острова — два уровня и наведение

**Files:**
- Create: `Sources/CodeCatApp/IslandMenuView.swift`
- Create: `Sources/CodeCatApp/HoverHostingView.swift`
- Modify: `Sources/CodeCatApp/IslandController.swift`

**Interfaces:**
- Consumes: `SessionListView`, `SettingsSectionView` (Task 6), `IslandLayout.menuFrame` (Task 1).
- Produces: `IslandMenuLevel` (`.short`, `.full`), `IslandMenuView(appState:level:onJump:)`, `HoverHostingView<Content>`.

- [ ] **Step 1: Хост с отслеживанием наведения**

Создай `Sources/CodeCatApp/HoverHostingView.swift`:

```swift
import AppKit
import SwiftUI

/// `NSHostingView`, который сообщает о входе и выходе курсора.
///
/// Наведение здесь ловится `NSTrackingArea`, а не SwiftUI-хавером, по двум
/// причинам: окно острова не должно активироваться и перехватывать фокус, и
/// событие нужно даже когда приложение не активно (`.activeAlways`).
class HoverHostingView<Content: View>: NSHostingView<Content> {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        // `.inVisibleRect` избавляет от пересчёта прямоугольника при каждом
        // изменении размера окна — а оно меняется при смене облика.
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}

/// Хост острова: вдобавок к наведению отдаёт клик.
///
/// `mouseDown` намеренно пустой, а действие висит на `mouseUp`: так клик не
/// срабатывает, если пользователь нажал на острове и отпустил в стороне.
final class IslandHostingView: HoverHostingView<IslandView> {
    var onClick: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { }
    override func mouseUp(with event: NSEvent) { onClick?() }
}
```

- [ ] **Step 2: Написать меню**

Создай `Sources/CodeCatApp/IslandMenuView.swift`:

```swift
import SwiftUI
import CodeCatCore

/// Насколько подробное меню показывается.
enum IslandMenuLevel {
    /// Наведение: только список сессий. Мышь могла заехать на остров случайно,
    /// и полэкрана настроек в ответ на это — слишком.
    case short
    /// Клик: всё, что есть в панели плавающего режима.
    case full
}

/// Меню острова. То же содержимое, что и в панели плавающего режима, но на
/// абсолютно чёрном фоне: чёрное меню под чёрной плашкой читается как одно целое
/// с физическим вырезом, а любой материал или прозрачность выдали бы шов.
struct IslandMenuView: View {
    @ObservedObject var appState: AppState
    let level: IslandMenuLevel
    var onJump: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SessionListView(appState: appState, onJump: onJump)
            if level == .full {
                separator
                SettingsSectionView(appState: appState)
            }
        }
        .font(.system(size: 12))
        .padding(14)
        .frame(width: 290, alignment: .leading)
        .background(Color.black)
        .clipShape(BottomRoundedRectangle(radius: IslandLayout.cornerRadius))
        // Содержимое написано под системную тему: на чёрном фоне оно обязано
        // считать себя тёмной темой, иначе `.secondary` и `.tertiary` окажутся
        // чёрными на чёрном при светлом оформлении системы.
        .environment(\.colorScheme, .dark)
    }

    /// Системный `Divider` на чистом чёрном почти не виден.
    private var separator: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(height: 1)
    }
}
```

- [ ] **Step 3: Машина состояний в контроллере**

В `Sources/CodeCatApp/IslandController.swift` добавь свойства:

```swift
    private var menuPanel: OverlayPanel?
    private var menuLevel: IslandMenuLevel?
    private var pendingClose: DispatchWorkItem?
```

Замени создание хоста в `setVisible(_:)` на `IslandHostingView` и подпиши обработчики (там, где раньше ставился `NSHostingView`):

```swift
        if let hosting = panel.contentView as? IslandHostingView {
            hosting.rootView = content(for: geometry)
        } else {
            let hosting = IslandHostingView(rootView: content(for: geometry))
            hosting.onEnter = { [weak self] in self?.pointerEnteredRegion() }
            hosting.onExit = { [weak self] in self?.pointerLeftRegion() }
            hosting.onClick = { [weak self] in self?.islandClicked() }
            panel.contentView = hosting
        }
```

И добавь методы:

```swift
    // MARK: - Наведение и клик

    /// Курсор внутри острова или внутри меню — это один регион: пока он в любом из
    /// двух окон, короткое меню живёт. Иначе оно закрывалось бы ровно в тот момент,
    /// когда мышь переходит с острова на меню, то есть всегда.
    private func pointerEnteredRegion() {
        pendingClose?.cancel()
        pendingClose = nil
        if menuLevel == nil { showMenu(.short) }
    }

    private func pointerLeftRegion() {
        // Полное меню закрывается только кликом мимо: в нём тумблеры и выбор
        // облика, и оно не должно исчезать, пока пользователь ведёт мышь к нужному
        // переключателю.
        guard menuLevel == .short else { return }
        pendingClose?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Опрос реального положения курсора, а не доверие порядку событий.
            // Остров и меню — два разных окна, и на переходе между ними AppKit
            // шлёт `mouseExited` острова и `mouseEntered` меню без гарантии
            // порядка. Полагаться на то, что `mouseEntered` успеет отменить это
            // задание, нельзя: при обратном порядке меню закрывалось бы ровно в
            // тот момент, когда пользователь до него дотянулся.
            guard !self.pointerIsInsideRegion() else { return }
            self.hideMenu()
        }
        pendingClose = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Курсор внутри острова или внутри меню. `NSEvent.mouseLocation` — в тех же
    /// экранных координатах, что и `NSWindow.frame`.
    private func pointerIsInsideRegion() -> Bool {
        let point = NSEvent.mouseLocation
        if let island = islandPanel, island.isVisible, island.frame.contains(point) { return true }
        if let menu = menuPanel, menu.isVisible, menu.frame.contains(point) { return true }
        return false
    }

    private func islandClicked() {
        if menuLevel == .full {
            hideMenu()
        } else {
            showMenu(.full)
        }
    }

    private func showMenu(_ level: IslandMenuLevel) {
        guard let geometry = geometry() else { return }
        hideMenu()

        // Полное меню обязано становиться key, иначе тумблеры и кнопки внутри не
        // получают кликов; короткому это не нужно, и ему незачем трогать фокус.
        let panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 290, height: 200),
                                 allowsKey: level == .full)
        panel.level = Self.islandLevel
        panel.acceptsMouseMovedEvents = true
        let hosting = HoverHostingView(rootView: IslandMenuView(
            appState: appState,
            level: level,
            onJump: { [weak self] in self?.hideMenu() }))
        hosting.onEnter = { [weak self] in self?.pointerEnteredRegion() }
        hosting.onExit = { [weak self] in self?.pointerLeftRegion() }
        panel.contentView = hosting

        menuPanel = panel
        menuLevel = level
        layoutMenu(geometry: geometry)

        if level == .full {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    /// Панель уводится с экрана и отпускается, а не прячется для повторного
    /// использования: внутри полного меню живут восемь превью обликов, каждое со
    /// своим таймером анимации, и держать их между открытиями — ровно тот расход
    /// батареи, которого спек обликов велел избегать. Та же причина, что и у
    /// `OverlayController.hideDetails()`.
    private func hideMenu() {
        pendingClose?.cancel()
        pendingClose = nil
        menuPanel?.orderOut(nil)
        menuPanel = nil
        menuLevel = nil
    }

    private func layoutMenu(geometry: Geometry) {
        guard let panel = menuPanel,
              let hosting = panel.contentView else { return }
        let fitting = hosting.fittingSize
        let size = (fitting.width > 0 && fitting.height > 0)
            ? fitting : CGSize(width: 290, height: 200)
        panel.setContentSize(size)
        panel.setFrame(IslandLayout.menuFrame(island: geometry.island,
                                              size: size,
                                              screenFrame: geometry.screen.frame),
                       display: true)
    }
```

- [ ] **Step 4: Закрывать полное меню кликом мимо**

В `init(appState:)` контроллера добавь наблюдателя, а в `deinit` — снятие. Это тот же приём, что и в `OverlayController`:

```swift
        NotificationCenter.default.addObserver(
            self, selector: #selector(menuDidResignKey(_:)),
            name: NSWindow.didResignKeyNotification, object: nil)
```

```swift
    /// Непривязанная панель, ставшая key, может её потерять — пользователь кликнул
    /// в другое окно или по рабочему столу. Для полного меню это «клик мимо».
    /// Короткое меню key никогда не становится, поэтому сюда не попадает.
    @objc private func menuDidResignKey(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel, panel === menuPanel else { return }
        hideMenu()
    }
```

В `deinit` добавь `NotificationCenter.default.removeObserver(self)` и `menuPanel?.orderOut(nil)`.

В `setVisible(_:)`, в ветке скрытия, тоже закрывай меню — иначе оно осталось бы висеть без острова:

```swift
        guard visible, let geometry = geometry() else {
            hideMenu()
            islandPanel?.orderOut(nil)
            return
        }
```

А в `handleStateChange()` переставляй открытое меню под изменившуюся геометрию:

```swift
    private func handleStateChange() {
        setVisible(appState.showMascot)
        if menuPanel != nil, let geometry = geometry() {
            layoutMenu(geometry: geometry)
        }
    }
```

- [ ] **Step 5: Собрать и проверить руками**

```bash
swift build && make app && open dist/CodeCat.app
```

Отдельно проверь повторный клик по острову при открытом полном меню. Панель острова не может стать key (`allowsKey: false`), поэтому клик по ней не должен отбирать key у меню — но если AppKit всё-таки пришлёт `didResignKey`, порядок получится такой: меню закрылось по резигну, `menuLevel` стал `nil`, и `islandClicked()` откроет его заново вместо закрытия. Симптом — «клик по острову не закрывает меню». Лечится запоминанием момента последнего клика по острову и игнорированием резигна, пришедшего в те же миллисекунды; не закладываем это заранее, потому что срабатывания может и не быть.

Ожидаемое: наведение на остров открывает чёрное меню со списком сессий; проход мышью с острова на меню его не закрывает; уход в сторону закрывает через треть секунды. Клик по острову раскрывает полное меню с обликами и тумблерами; они работают; клик мимо закрывает; повторный клик по острову закрывает. Клик по строке сессии прыгает в терминал и закрывает меню.

- [ ] **Step 6: Коммит**

```bash
git add Sources/CodeCatApp/IslandMenuView.swift Sources/CodeCatApp/HoverHostingView.swift Sources/CodeCatApp/IslandController.swift
git commit -m "feat: меню острова в двух уровнях — по наведению и по клику"
```

---

### Task 8: Переключатель в панели, «прятать в покое», смена дисплеев

**Files:**
- Modify: `Sources/CodeCatApp/SettingsSectionView.swift`
- Modify: `Sources/CodeCatApp/IslandController.swift`

**Interfaces:**
- Consumes: `AppState.displayMode`, `AppState.islandHidesWhenIdle`, `AppState.islandShouldHideNow` (Task 3).
- Produces: ничего нового.

- [ ] **Step 1: Сегмент выбора вида в настройках**

В `Sources/CodeCatApp/SettingsSectionView.swift` добавь в начало `VStack`, перед `SkinPickerView`:

```swift
            Text("Вид").font(.system(size: 12, weight: .medium))
            Picker("Вид", selection: $appState.displayMode) {
                ForEach(MascotDisplayMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if appState.displayMode == .island {
                Toggle("Прятать остров, когда сессий нет", isOn: $appState.islandHidesWhenIdle)
            }

            Divider()
```

- [ ] **Step 2: Учесть «прятать в покое» в контроллере**

В `Sources/CodeCatApp/IslandController.swift` в `setVisible(_:)` замени условие показа:

```swift
        // `islandShouldHideNow` — настройка «прятать, когда сессий нет». Меню при
        // этом тоже уходит: его не к чему было бы привязать.
        guard visible, !appState.islandShouldHideNow, let geometry = geometry() else {
            hideMenu()
            islandPanel?.orderOut(nil)
            return
        }
```

- [ ] **Step 3: Реагировать на смену конфигурации дисплеев**

В `init(appState:)` добавь ещё одного наблюдателя:

```swift
        // Встроенный экран могли отключить или подключить обратно — вырез при этом
        // появляется и исчезает, а вместе с ним и место для острова.
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
```

и метод:

```swift
    @objc private func screensChanged() {
        hideMenu()
        setVisible(isVisible)
    }
```

- [ ] **Step 4: Собрать и проверить руками**

```bash
swift build && make app && open dist/CodeCat.app
```

Ожидаемое: в панели плавающего режима появился сегмент «Кот / Остров», переключение работает в обе стороны; в режиме острова в полном меню появляется тумблер «Прятать остров, когда сессий нет», и при включённом тумблере без сессий остров исчезает, а с появлением сессии возвращается.

- [ ] **Step 5: Коммит**

```bash
git add Sources/CodeCatApp/SettingsSectionView.swift Sources/CodeCatApp/IslandController.swift
git commit -m "feat: выбор вида в панели, скрытие острова в покое, реакция на смену дисплеев"
```

---

### Task 9: Ручной чеклист и сборка бандла

**Files:**
- Modify: `docs/HANDOFF.md`

**Interfaces:**
- Consumes: всё предыдущее.
- Produces: ничего.

- [ ] **Step 1: Прогнать всё**

```bash
swift test && make app
```
Expected: все тесты зелёные, `make app` завершается строкой «Готово: dist/CodeCat.app» (внутри он ещё и проверяет, что ассеты обликов попали в бандл).

- [ ] **Step 2: Дописать чеклист**

В `docs/HANDOFF.md`, в раздел про то, что пользователь ещё не проверял глазами, добавь пункты 17–23:

```markdown
17. Остров совпадает по высоте с вырезом; шов между чёрной плашкой и вырезом не виден на светлых обоях.
18. Кот в крыле анимируется, пиксели квадратные (спрайт не мыльный), спрайт не обрезан сверху и снизу. Самые высокие облики (mxmaze, cat-4, cat-5) заполняют строку меню целиком — если это выглядит тесно, запасной ход описан в спеке: поднять высоту острова до `safeAreaInsets.top + 4`.
19. Счётчик справа: точка в покое, число при сессиях, красное число когда агент ждёт.
20. Наведение открывает короткое меню; переход мышью с острова на меню его не закрывает; уход в сторону закрывает примерно через треть секунды.
21. Клик открывает полное меню; тумблеры, выбор облика и кнопка хуков в нём работают; клик мимо закрывает; повторный клик по острову закрывает.
22. Клик по строке сессии прыгает в терминал и закрывает меню.
23. Переключение вида в обе стороны: плавающий кот возвращается на сохранённое место, остров исчезает без остатка; панель плавающего режима после распила выглядит и ведёт себя как раньше.
```

Туда же, в список известных мелочей, добавь честную оговорку:

```markdown
- Крылья острова перекрывают строку меню: клики по меню приложения слева и по статус-иконкам справа в зоне крыльев достаются острову. Это цена выбранной формы, крылья сделаны минимально возможными.
```

- [ ] **Step 3: Коммит**

```bash
git add docs/HANDOFF.md
git commit -m "docs: ручной чеклист острова и оговорка про перекрытие строки меню"
```

---

## Порядок и зависимости

```
1 (IslandLayout) ─┐
2 (SpriteScale)  ─┼─> 4 (пустой остров + переключение) ─> 5 (кот и счётчик) ─┐
3 (режим+AppState)┘                                                          ├─> 7 (меню) ─> 8 (настройки) ─> 9 (чеклист)
                       6 (распил панели) ────────────────────────────────────┘
```

Задачи 1–3 независимы и делаются в любом порядке. Задача 6 не зависит от 4 и 5, но обязана быть готова до 7.
