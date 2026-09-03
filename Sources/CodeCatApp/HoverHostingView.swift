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

/// Хост острова: вдобавок к наведению отдаёт клик — но только по самой полосе
/// острова.
///
/// Окно одно на остров и меню, поэтому «клик по острову» больше не равен «клик по
/// окну». Всё, что ниже полосы, принадлежит содержимому меню: тумблерам, выбору
/// облика, строкам сессий, — и туда события обязаны доходить нетронутыми, иначе
/// внутри меню перестанет работать всё сразу.
///
/// `mouseDown` по полосе намеренно проглатывается, а действие висит на `mouseUp`:
/// так клик не срабатывает, если пользователь нажал на острове и отпустил в стороне.
final class IslandHostingView: HoverHostingView<IslandView> {
    var onClick: (() -> Void)?
    /// Высота полосы острова, считая от верхней кромки окна.
    var islandStripHeight: CGFloat = 0

    /// Контур закрашенной площади в координатах SwiftUI (ось Y вниз, начало —
    /// левый верхний угол окна). Ставится контроллером вместе с рамкой окна.
    ///
    /// Нужен, потому что окно прямоугольное, а остров — нет. Форма уже вся в
    /// `IslandLayout.silhouettePath`, и без этой проверки прямоугольник окна
    /// перехватывает клики на площади, где не нарисовано ничего. Заметнее всего это
    /// в двух местах:
    ///
    ///  * **Галтели у кромки.** Верхние углы окна не закрашены НИКОГДА — форма там
    ///    вогнутая. Окно шире корпуса на `edgeRadius` с каждой стороны, и в этой
    ///    зоне клики по меню приложения слева и по статус-иконкам справа доставались
    ///    острову. Это было постоянным раздражителем, а не мгновением.
    ///  * **Раскрытие меню.** Окно встаёт в конечный размер сразу, а маска догоняет
    ///    пружиной (`revealedHeight`), поэтому доли секунды окно шире рисунка снизу.
    ///
    /// `nil` — проверка выключена, окно ведёт себя как обычный прямоугольник.
    var silhouette: CGPath?

    private func isInStrip(_ event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        return isFlipped
            ? point.y <= islandStripHeight
            : point.y >= bounds.height - islandStripHeight
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Точка в координатах SwiftUI-контура: ось Y вниз от верхней кромки окна.
    /// `NSHostingView` перевёрнут, но полагаться на это молча нельзя — форма
    /// поехала бы вверх ногами, если это когда-нибудь изменится.
    private func silhouettePoint(_ pointInSelf: NSPoint) -> CGPoint {
        CGPoint(x: pointInSelf.x,
                y: isFlipped ? pointInSelf.y : bounds.height - pointInSelf.y)
    }

    /// Возвращает `nil` для точек вне закрашенной формы — тогда событие уходит
    /// туда, где оно и должно быть: в строку меню, в окно под островом, куда угодно.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let silhouette else { return super.hitTest(point) }
        // `hitTest` получает точку в координатах НАДвида, а не своих собственных.
        let local = superview.map { convert(point, from: $0) } ?? point
        guard bounds.contains(local) else { return super.hitTest(point) }
        guard silhouette.contains(silhouettePoint(local)) else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard isInStrip(event) else { super.mouseDown(with: event); return }
    }

    override func mouseUp(with event: NSEvent) {
        guard isInStrip(event) else { super.mouseUp(with: event); return }
        onClick?()
    }
}
