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
