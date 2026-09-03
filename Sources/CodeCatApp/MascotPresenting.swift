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

    /// Opens the mascot's menu without a click.
    ///
    /// Only `--demo` calls this, and only so `scripts/capture-screenshots.sh` can
    /// photograph the session list and the skin grid — both of which are otherwise
    /// reachable only by moving a real pointer onto a window that screen-control
    /// tools cannot see (the app is `LSUIElement`). It is a separate method rather
    /// than a synthesized click for exactly that reason: there is nothing to
    /// synthesize a click *onto* from outside.
    func openMenuForCapture()
}
