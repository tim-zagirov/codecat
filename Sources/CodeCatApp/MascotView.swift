import SwiftUI
import CodeCatCore

/// Renders the current sprite skin, falling back to the hand-drawn `CatView` when it
/// cannot be loaded.
///
/// The hand-drawn cat is no longer something the user can choose in `SkinPickerView`
/// — every `MascotSkin` in `MascotSkins.all` is sprite-backed. `CatView` survives
/// only as this fallback, so the mascot is never missing even if a sprite sheet goes
/// missing from the bundle; the user is told about it separately, once, by
/// `AppState.reportSkinLoadFailure`.
struct MascotView: View {
    let skin: MascotSkin
    let status: AggregateStatus
    let sessionCount: Int
    /// Размеры для острова. Не заданы — канва и нормировка плавающего маскота.
    var drawingSize: CGSize?
    var canvasSize: CGSize?
    var showsBadge: Bool = true
    /// Called when a sprite skin could not be loaded, so the app can report it.
    var onLoadFailure: (MascotSkin) -> Void = { _ in }

    var body: some View {
        content
            // Deliberately NOT `.onAppear` on the fallback branch below: a skin that
            // fails to load renders `CatView` in the same `else` branch of `content`
            // regardless of which skin it was. A `ViewBuilder` if/else gives each
            // branch a fixed structural identity, so switching from one broken skin
            // to another while staying in that branch updates the existing view in
            // place instead of recreating it — `.onAppear` would silently never fire
            // again. Keying `.task` on `skin.id` instead ties the check to the skin
            // itself, so it re-runs on every skin change regardless of which branch
            // renders. Do not "simplify" this back into `.onAppear` — that
            // reintroduces the silent-failure bug.
            .task(id: skin.id) {
                if SpriteSheetStore.shared.load(skin) == nil {
                    onLoadFailure(skin)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let loaded = SpriteSheetStore.shared.load(skin) {
            SpriteMascotView(loaded: loaded, status: status, sessionCount: sessionCount,
                             showsBadge: showsBadge,
                             drawingSize: drawingSize, canvasSize: canvasSize)
        } else {
            CatView(status: status, sessionCount: sessionCount)
        }
    }
}
