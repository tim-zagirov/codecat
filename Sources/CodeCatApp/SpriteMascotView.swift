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
    /// Размер спрайта на экране. Не задан — берётся размер из `LoadedSkin`,
    /// то есть нормировка плавающего маскота.
    var drawingSize: CGSize?
    /// Размер холста вокруг спрайта. Не задан — канва плавающего маскота.
    var canvasSize: CGSize?
    /// Момент, когда состояние началось. Нужен движениям из нескольких фаз
    /// («потянулся — улёгся — спит»): без точки отсчёта нельзя сказать, отыграна ли
    /// уже одноразовая часть. `nil` — привязка к стенным часам, как было раньше;
    /// для бесконечной петли из одной фазы разницы никакой, поэтому превью в панели
    /// его не передают.
    var since: Date?

    private var animation: SpriteAnimation? {
        loaded.skin.animation(for: AggregateStatusKey(status))
    }

    var body: some View {
        ZStack {
            if let animation, !animation.frames.isEmpty {
                // Тикаем по самой быстрой фазе: расписание `TimelineView` задаётся
                // один раз, а фазы у движения бывают разной скорости, и медленный тик
                // просто съел бы кадры быстрой фазы. Перерисовка здесь — подмена
                // одной маленькой картинки.
                // Пол ограничения совпадает с инвариантом реестра (0.6–8 fps).
                let fps = min(max(animation.phases.map(\.framesPerSecond).max() ?? 1, 0.6), maxFPS)
                TimelineView(.periodic(from: .now, by: 1 / fps)) { context in
                    frameImage(at: elapsed(at: context.date), in: animation)
                }
            }
            if showsBadge {
                MascotBadge(sessionCount: sessionCount, status: status)
            }
        }
        .frame(width: canvasSize?.width ?? MascotLayout.canvasSize,
               height: canvasSize?.height ?? MascotLayout.canvasSize)
    }

    /// Сколько секунд прошло с начала состояния. Считается от времени, а не от
    /// счётчика внутри вида: `TimelineView` пересобирает тело на каждый тик, а сам
    /// вид пересоздаётся при каждом закрытии панели и смене облика — движение не
    /// имеет права начинаться заново от этого.
    private func elapsed(at date: Date) -> TimeInterval {
        guard let since else { return date.timeIntervalSinceReferenceDate }
        return date.timeIntervalSince(since)
    }

    @ViewBuilder
    private func frameImage(at elapsed: TimeInterval, in animation: SpriteAnimation) -> some View {
        let size = drawingSize ?? loaded.drawingSize
        if let frame = SpriteTimeline.frame(at: elapsed, in: animation),
           let cgImage = SpriteSheetStore.shared.image(
            for: frame, of: loaded.skin, cropping: loaded.bounds) {
            Image(decorative: cgImage, scale: 1)
                .interpolation(.none)
                .antialiased(false)
                .resizable()
                .frame(width: size.width, height: size.height)
        }
    }
}
