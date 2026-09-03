import SwiftUI
import CodeCatCore

/// Draws the current frame of a sprite skin.
///
/// Two rules make pixel art survive on screen: `.interpolation(.none)` and an
/// integer magnification. Anything else turns a 16x16 kitten into mush.
@MainActor
struct SpriteMascotView: View {
    let loaded: LoadedSkin
    let status: AggregateStatus
    let sessionCount: Int
    /// Previews in the details panel cap this: nine animations run at once there.
    var maxFPS: Double = 8
    var showsBadge: Bool = true
    /// The sprite's size on screen. Unset means the size from `LoadedSkin`, i.e. the
    /// floating mascot's scale.
    var drawingSize: CGSize?
    /// Size of the canvas around the sprite. Unset means the floating mascot's canvas.
    var canvasSize: CGSize?
    /// When the state began. Needed by movements made of several phases ("stretch —
    /// lie down — sleep"): without a reference point there is no telling whether the
    /// one-shot part has already played. `nil` means anchoring to the wall clock, as
    /// it used to be; for an endless single-phase loop it makes no difference, which
    /// is why the panel's previews do not pass it.
    var since: Date?

    private var animation: SpriteAnimation? {
        loaded.skin.animation(for: AggregateStatusKey(status))
    }

    var body: some View {
        ZStack {
            if let animation, !animation.frames.isEmpty {
                // Tick at the fastest phase's rate: `TimelineView`'s schedule is set
                // once, a movement's phases run at different speeds, and a slow tick
                // would simply eat the fast phase's frames. Redrawing here means
                // swapping one small image.
                // The floor matches the registry's invariant (0.6–8 fps).
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

    /// How many seconds have passed since the state began. Measured from a time rather
    /// than a counter inside the view: `TimelineView` rebuilds the body on every tick,
    /// and the view itself is recreated every time the panel closes and the skin
    /// changes — a movement has no business restarting because of that.
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
