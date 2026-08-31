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
    private var menuPanel: OverlayPanel?
    private var menuLevel: IslandMenuLevel?
    private var pendingClose: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []
    /// Последняя запрошенная видимость острова. Читает её `screensChanged()`: она
    /// зовёт `setVisible(isVisible)`, чтобы перепоказать остров после смены
    /// конфигурации дисплеев, не спрашивая заново `AppState.showMascot` (который к
    /// этому моменту мог и не измениться).
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

        NotificationCenter.default.addObserver(
            self, selector: #selector(menuDidResignKey(_:)),
            name: NSWindow.didResignKeyNotification, object: nil)

        // Встроенный экран могли отключить или подключить обратно — вырез при этом
        // появляется и исчезает, а вместе с ним и место для острова.
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        setVisible(appState.showMascot)
    }

    deinit {
        // Панель надо увести с экрана явно: контроллер умирает при смене режима,
        // и оставленное видимым окно пережило бы его.
        NotificationCenter.default.removeObserver(self)
        menuPanel?.orderOut(nil)
        islandPanel?.orderOut(nil)
    }

    func setVisible(_ visible: Bool) {
        isVisible = visible
        // `islandShouldHideNow` — настройка «прятать, когда сессий нет». Меню при
        // этом тоже уходит: его не к чему было бы привязать.
        guard visible, !appState.islandShouldHideNow, let geometry = geometry() else {
            hideMenu()
            islandPanel?.orderOut(nil)
            return
        }
        let panel = islandPanel ?? makePanel()
        islandPanel = panel
        if let hosting = panel.contentView as? IslandHostingView {
            hosting.rootView = content(for: geometry)
        } else {
            let hosting = IslandHostingView(rootView: content(for: geometry))
            hosting.onEnter = { [weak self] in self?.pointerEnteredRegion() }
            hosting.onExit = { [weak self] in self?.pointerLeftRegion() }
            hosting.onClick = { [weak self] in self?.islandClicked() }
            panel.contentView = hosting
        }
        panel.setFrame(geometry.island, display: true)
        panel.orderFrontRegardless()
    }

    private func handleStateChange() {
        setVisible(appState.showMascot)
        if menuPanel != nil, let geometry = geometry() {
            layoutMenu(geometry: geometry)
        }
    }

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

    /// Непривязанная панель, ставшая key, может её потерять — пользователь кликнул
    /// в другое окно или по рабочему столу. Для полного меню это «клик мимо».
    /// Короткое меню key никогда не становится, поэтому сюда не попадает.
    @objc private func menuDidResignKey(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel, panel === menuPanel else { return }
        hideMenu()
    }

    /// Экран сменил конфигурацию — вырез мог появиться или исчезнуть вместе с ним.
    /// `didChangeScreenParametersNotification` нигде не документирован как
    /// гарантированно приходящий на главном потоке (Apple подтверждает только сам
    /// факт отправки уведомления, не поток), а `geometry()` — через
    /// `assumeIsolated` — не прощает ошибку: не предупреждает о нарушении, а
    /// роняет процесс. Поэтому переход на главный поток здесь сделан явно, а не
    /// просто предположен.
    @objc private func screensChanged() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.screensChanged() }
            return
        }
        hideMenu()
        setVisible(isVisible)
    }

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

    /// Экран с вырезом и вся производная геометрия. `nil` — острову негде жить.
    private func geometry() -> Geometry? {
        // Ищем сразу по тому, что нужно — по первому экрану, для которого
        // строится вырез, а не по `safeAreaInsets.top > 0` (`IslandLayout.hasNotch`).
        // Порядок `NSScreen.screens` нигде не документирован как «встроенный
        // первым», и поведение `safeAreaInsets.top` на внешних дисплеях не
        // проверено. Если бы фильтр стоял на инсете, а не на самом вырезе, экран
        // без выреза, но с ненулевым инсетом, мог бы прокрасться первым и
        // остановить поиск до того, как встроенный экран будет рассмотрен —
        // остров молча не появился бы. `hasNotch` при этом не лишний: это
        // самостоятельный документированный предикат со своим тестом, просто не
        // единственный фильтр здесь.
        guard let found = NSScreen.screens.lazy.compactMap({ screen in
            IslandLayout.notchRect(auxLeft: screen.auxiliaryTopLeftArea,
                                   auxRight: screen.auxiliaryTopRightArea).map { (screen, $0) }
        }).first
        else { return nil }
        let (screen, notch) = found

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
        // `geometry()` ведут шесть вызовов:
        //  - из `init` (через `setVisible(appState.showMascot)`);
        //  - из `handleStateChange()` дважды — через `setVisible(...)` и напрямую,
        //    при перекладке уже открытого меню под новую геометрию;
        //  - из `pointerEnteredRegion()` (через `showMenu(.short)`) — вызывается из
        //    `mouseEntered` хоста острова и хоста меню;
        //  - из `islandClicked()` (через `showMenu(.full)`) — вызывается из
        //    `mouseUp` хоста острова;
        //  - из `screensChanged()` (через `setVisible(isVisible)`) — сама явно
        //    переходит на главный поток перед вызовом, см. её комментарий.
        // `handleStateChange()` доходит сюда через `Combine`-сток с
        // `.receive(on: DispatchQueue.main)`, а `pointerEnteredRegion()` и
        // `islandClicked()` — из переопределений `NSResponder.mouseEntered` /
        // `mouseUp`, которые AppKit всегда доставляет на главном потоке. Если
        // появится путь не с главного потока, `assumeIsolated` не предупредит об
        // этом, а уронит процесс — держи это в уме при правках.
        // Есть и седьмой путь: `setVisible(false)` из `AppDelegate.syncPresenter()`
        // (сам он выполняется на главном потоке). Сегодня он до `geometry()` не
        // доходит — `guard visible` в `setVisible` отсекает его раньше. Если
        // `setVisible(false)` когда-нибудь начнёт считать геометрию, этот путь
        // придётся проверить отдельно.
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
