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
    private var menuLevel: IslandMenuLevel?
    /// Меню схлопывается пружиной, но его содержимое ещё смонтировано: снимут его
    /// по `pendingTeardown`.
    private var isCollapsing = false
    /// Какой уровень меню сейчас схлопывается: содержимое обязано остаться на
    /// экране, пока силуэт едет обратно, иначе схлопывать будет нечего.
    private var collapsingLevel: IslandMenuLevel?
    private var pendingClose: DispatchWorkItem?
    /// Уборка окна меню после того, как анимация закрытия доехала. Держится
    /// отдельно от `pendingClose` (та решает, *закрывать ли* короткое меню по уходу
    /// курсора): открыть меню заново можно прямо посреди закрытия, и тогда уборку
    /// надо отменить, не трогая логику наведения.
    private var pendingTeardown: DispatchWorkItem?
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
        islandPanel?.orderOut(nil)
    }

    func setVisible(_ visible: Bool) {
        isVisible = visible
        // `mascotShouldHideNow` — настройка «прятать, когда сессий нет». Меню при
        // этом тоже уходит: его не к чему было бы привязать.
        guard visible, !appState.mascotShouldHideNow, let geometry = geometry() else {
            dropMenu()
            islandPanel?.orderOut(nil)
            return
        }
        let panel = islandPanel ?? makePanel()
        islandPanel = panel
        let hosting = self.hosting(of: panel) ?? {
            let hosting = IslandHostingView(rootView: content(for: geometry))
            hosting.onEnter = { [weak self] in self?.pointerEnteredRegion() }
            hosting.onExit = { [weak self] in self?.pointerLeftRegion() }
            hosting.onClick = { [weak self] in self?.islandClicked() }
            panel.contentView = hosting
            return hosting
        }()
        hosting.rootView = content(for: geometry)
        hosting.islandStripHeight = geometry.island.height
        panel.setFrame(windowFrame(for: geometry, hosting: hosting), display: true)
        panel.orderFrontRegardless()
    }

    private func handleStateChange() {
        setVisible(appState.showMascot)
    }

    // MARK: - Наведение и клик

    /// Курсор внутри окна. Окно теперь одно на остров и меню, поэтому и вопрос
    /// один: раньше приходилось спрашивать про два окна и следить, чтобы переход
    /// мышью с острова на меню не считался уходом.
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
            // Опрос реального положения курсора, а не доверие порядку событий:
            // окно в этот момент уже могло вырасти под курсором.
            guard !self.pointerIsInsideRegion() else { return }
            self.hideMenu()
        }
        pendingClose = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// `NSEvent.mouseLocation` — в тех же экранных координатах, что и `NSWindow.frame`.
    private func pointerIsInsideRegion() -> Bool {
        guard let panel = islandPanel, panel.isVisible else { return false }
        return panel.frame.contains(NSEvent.mouseLocation)
    }

    private func islandClicked() {
        switch menuLevel {
        case .full: hideMenu()
        case .short: expandMenu()
        case nil: showMenu(.full)
        }
    }

    /// Переход «короткое → полное» — это смена содержимого в том же окне, без
    /// пересоздания: список сессий не имеет права мигнуть и пересобраться. Высота
    /// доезжает той же пружиной внутри `IslandView`.
    private func expandMenu() {
        guard let panel = islandPanel, let hosting = hosting(of: panel),
              let geometry = geometry() else { return }
        menuLevel = .full
        hosting.rootView = content(for: geometry)
        panel.setFrame(windowFrame(for: geometry, hosting: hosting), display: true)
        // Полное меню обязано становиться key, иначе тумблеры, переключатель вида
        // и кнопка хуков внутри него не получают кликов.
        panel.makeKeyAndOrderFront(nil)
    }

    /// See `MascotPresenting.openMenuForCapture()`.
    func openMenuForCapture() {
        showMenu(.full)
    }

    private func showMenu(_ level: IslandMenuLevel) {
        guard let panel = islandPanel, let hosting = hosting(of: panel),
              let geometry = geometry() else { return }
        pendingTeardown?.cancel()
        pendingTeardown = nil
        isCollapsing = false
        collapsingLevel = nil
        menuLevel = level
        hosting.rootView = content(for: geometry)
        panel.setFrame(windowFrame(for: geometry, hosting: hosting), display: true)
        if level == .full {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    /// - Parameter animated: закрывать пружиной, зеркально раскрытию. `false` —
    ///   для путей, где ждать нельзя: остров уходит с экрана целиком, меняется
    ///   режим отображения, на его месте немедленно открывается другое меню.
    private func hideMenu(animated: Bool = true) {
        pendingClose?.cancel()
        pendingClose = nil
        pendingTeardown?.cancel()
        pendingTeardown = nil

        guard animated, menuLevel != nil, let panel = islandPanel,
              let hosting = hosting(of: panel), let geometry = geometry() else {
            dropMenu()
            return
        }

        // Меню больше не считается открытым с этого момента: клик по острову во
        // время закрытия обязан открыть его заново, а не закрыть повторно. Само
        // содержимое остаётся смонтированным — силуэт его схлопывает.
        collapsingLevel = menuLevel
        menuLevel = nil
        isCollapsing = true
        hosting.rootView = content(for: geometry)

        let teardown = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingTeardown = nil
            self.dropMenu()
        }
        pendingTeardown = teardown
        DispatchQueue.main.asyncAfter(deadline: .now() + IslandView.revealDuration,
                                      execute: teardown)
    }

    /// Снимает содержимое меню и сжимает окно обратно до полосы острова. Окно
    /// держится тем же, что и было: это одна форма, а не две.
    private func dropMenu() {
        pendingTeardown?.cancel()
        pendingTeardown = nil
        menuLevel = nil
        isCollapsing = false
        collapsingLevel = nil
        guard let panel = islandPanel, let hosting = hosting(of: panel),
              let geometry = geometry() else { return }
        hosting.rootView = content(for: geometry)
        panel.setFrame(windowFrame(for: geometry, hosting: hosting), display: true)
    }

    private func hosting(of panel: OverlayPanel) -> IslandHostingView? {
        panel.contentView as? IslandHostingView
    }

    /// Рамка окна под текущее содержимое. Высоту спрашиваем у самой вёрстки
    /// (`fittingSize`), а не считаем: меню собирается из списка сессий и настроек,
    /// и его высота зависит от того, сколько сессий сейчас есть.
    private func windowFrame(for geometry: Geometry, hosting: IslandHostingView) -> NSRect {
        let fitting = hosting.fittingSize.height
        let total = fitting > 0 ? fitting : geometry.island.height
        return IslandLayout.windowFrame(island: geometry.island,
                                        totalHeight: total,
                                        screenFrame: geometry.screen.frame)
    }

    @objc private func menuDidResignKey(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel, panel === islandPanel,
              menuLevel == .full else { return }
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
        // `allowsKey: true`: окно одно на остров и меню, а в полном меню живут
        // тумблеры и кнопки — без права становиться key они не получают кликов.
        // Ключевым окно делается только по клику (`makeKeyAndOrderFront`), наведение
        // показывает меню через `orderFrontRegardless` и фокус не трогает.
        let panel = OverlayPanel(contentRect: .zero, allowsKey: true)
        panel.level = Self.islandLevel
        panel.acceptsMouseMovedEvents = true
        return panel
    }

    private func content(for geometry: Geometry) -> IslandView {
        IslandView(appState: appState,
                   notchWidth: geometry.notch.width,
                   wingWidth: IslandLayout.wingWidth,
                   spriteSize: geometry.spriteSize,
                   height: geometry.island.height,
                   menuLevel: menuLevel ?? (isCollapsing ? collapsingLevel : nil),
                   isCollapsing: isCollapsing,
                   onJump: { [weak self] in self?.hideMenu() })
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
        return Geometry(screen: screen,
                        notch: notch,
                        island: IslandLayout.islandFrame(notch: notch),
                        spriteSize: spriteSize)
    }
}
