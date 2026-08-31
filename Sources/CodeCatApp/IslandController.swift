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
    /// Последняя запрошенная видимость острова. Сегодня её никто не читает —
    /// читатель появится в задаче 8: `screensChanged()` будет звать
    /// `setVisible(isVisible)`, чтобы перепоказать остров после смены
    /// конфигурации дисплеев, не спрашивая заново `AppState.showMascot`
    /// (который к этому моменту мог и не измениться).
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

        // `SpriteSheetStore` изолирован `@MainActor` (см. его доккомментарий: все
        // вызывающие уже работают на главном потоке). Сам `IslandController` не
        // помечен `@MainActor` — это каскадом потянуло бы `@MainActor` на
        // `AppDelegate`, а оттуда — на глобальный `delegate` в `main.swift`, то есть
        // далеко за рамки этой задачи. Но фактически сюда всегда приходят с
        // главного потока: AppKit-панели и `Combine`-сток, подписанный через
        // `.receive(on: DispatchQueue.main)`. `assumeIsolated` просто констатирует
        // этот факт, а не меняет архитектуру.
        //
        // Инвариант: всякий путь сюда приходит на главном потоке. Сегодня в
        // `geometry()` ведут ровно два вызова — из `init` (через
        // `setVisible(appState.showMascot)`) и из `handleStateChange()` — и оба на
        // главном потоке. Если появится третий путь не с главного потока,
        // `assumeIsolated` не предупредит об этом, а уронит процесс — держи это в
        // уме при правках.
        let spriteSize = MainActor.assumeIsolated {
            SpriteSheetStore.shared.load(appState.skin)?
                .drawingSize(targetHeight: SpriteScale.islandTargetHeight,
                             maxWidth: SpriteScale.islandMaxWidth)
        } ?? CGSize(width: 24, height: 24)
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
