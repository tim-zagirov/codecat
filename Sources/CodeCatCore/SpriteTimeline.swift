import Foundation

/// Какой кадр показывать через `elapsed` секунд после того, как состояние началось.
///
/// Чистая функция от времени, без счётчика и без состояния: вид маскота
/// пересоздаётся постоянно (открылась панель, сменился облик, перерисовался остров),
/// и движение не имеет права начинаться заново при каждой перерисовке. Всё, что для
/// этого нужно, — момент входа в состояние; его знает `AppState`, и он переживает
/// любую пересборку вида.
public enum SpriteTimeline {

    /// Кадр в момент `elapsed`. `nil` только у пустой анимации.
    ///
    /// Отрицательный `elapsed` (часы перевели назад) читается как «состояние только
    /// что началось» — это лучше, чем показать кадр из середины перехода.
    public static func frame(at elapsed: TimeInterval, in animation: SpriteAnimation) -> SpriteFrame? {
        var remaining = max(0, elapsed)
        for phase in animation.phases {
            // Пустая или остановленная фаза не съедает движение: её просто нет.
            guard !phase.frames.isEmpty, phase.framesPerSecond > 0 else { continue }
            // Без счётчика повторений фаза крутится вечно — дальше идти некуда.
            guard let repeats = phase.repeats else {
                return phase.frames[wrappedIndex(remaining, phase)]
            }
            let duration = Double(phase.frames.count) / phase.framesPerSecond * Double(max(0, repeats))
            if remaining < duration {
                return phase.frames[wrappedIndex(remaining, phase)]
            }
            remaining -= duration
        }
        // Все фазы конечны и уже отыграны — замираем на последнем кадре, а не
        // возвращаемся к началу: движение закончилось, и повторять его незачем.
        return animation.phases.last(where: { !$0.frames.isEmpty })?.frames.last
    }

    private static func wrappedIndex(_ elapsed: TimeInterval, _ phase: SpritePhase) -> Int {
        let count = phase.frames.count
        let ticks = Int((elapsed * phase.framesPerSecond).rounded(.down))
        return ((ticks % count) + count) % count
    }
}
