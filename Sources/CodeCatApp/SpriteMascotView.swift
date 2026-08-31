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

    private var animation: SpriteAnimation? {
        loaded.skin.animation(for: AggregateStatusKey(status))
    }

    var body: some View {
        ZStack {
            if let animation, !animation.frames.isEmpty {
                // Clamp floor matches the documented invariant (0.6-8 fps) that the
                // registry tests enforce on every shipped animation.
                let fps = min(max(animation.framesPerSecond, 0.6), maxFPS)
                TimelineView(.periodic(from: .now, by: 1 / fps)) { context in
                    frameImage(at: frameIndex(for: context.date, fps: fps, count: animation.frames.count),
                               in: animation)
                }
            }
            if showsBadge {
                MascotBadge(sessionCount: sessionCount, status: status)
            }
        }
        .frame(width: canvasSize?.width ?? MascotLayout.canvasSize,
               height: canvasSize?.height ?? MascotLayout.canvasSize)
    }

    /// Frame number from wall-clock time rather than a stored counter: `TimelineView`
    /// re-evaluates this body on every tick, and a view that is torn down and
    /// rebuilt (the panel closing, the skin changing) must not restart mid-motion or
    /// hold state that outlives it.
    private func frameIndex(for date: Date, fps: Double, count: Int) -> Int {
        let ticks = Int((date.timeIntervalSinceReferenceDate * fps).rounded(.down))
        return ((ticks % count) + count) % count
    }

    @ViewBuilder
    private func frameImage(at index: Int, in animation: SpriteAnimation) -> some View {
        let size = drawingSize ?? loaded.drawingSize
        if let cgImage = SpriteSheetStore.shared.image(
            for: animation.frames[index], of: loaded.skin, cropping: loaded.bounds) {
            Image(decorative: cgImage, scale: 1)
                .interpolation(.none)
                .antialiased(false)
                .resizable()
                .frame(width: size.width, height: size.height)
        }
    }
}
