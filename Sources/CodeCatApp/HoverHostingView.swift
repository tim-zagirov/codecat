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

    private func isInStrip(_ event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        return isFlipped
            ? point.y <= islandStripHeight
            : point.y >= bounds.height - islandStripHeight
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isInStrip(event) else { super.mouseDown(with: event); return }
    }

    override func mouseUp(with event: NSEvent) {
        guard isInStrip(event) else { super.mouseUp(with: event); return }
        onClick?()
    }
}
