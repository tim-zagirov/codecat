import SwiftUI
import CodeCatCore

/// Picks between the hand-drawn cat and a sprite skin.
///
/// A sprite skin that fails to load falls back to the drawn cat right here, so the
/// mascot is never missing — the user is told about it separately, once, by
/// `AppState.reportSkinLoadFailure`.
struct MascotView: View {
    let skin: MascotSkin
    let status: AggregateStatus
    let sessionCount: Int
    /// Called when a sprite skin could not be loaded, so the app can report it.
    var onLoadFailure: (MascotSkin) -> Void = { _ in }

    var body: some View {
        content
            // Deliberately NOT `.onAppear` on the drawn-cat branch below: the drawn
            // cat and a sprite skin that failed to load both render `CatView` in the
            // same `else` branch of `content`. A `ViewBuilder` if/else gives each
            // branch a fixed structural identity, so switching skins while staying in
            // that branch (e.g. drawn -> a broken sprite skin) updates the existing
            // view in place instead of recreating it — `.onAppear` would silently
            // never fire again. Keying `.task` on `skin.id` instead ties the check to
            // the skin itself, so it re-runs on every skin change regardless of which
            // branch renders. It also runs outside body evaluation, which matters
            // because `onLoadFailure` ultimately mutates `@Published` state
            // (`AppState.skinID`) and must not do that mid-render. Do not "simplify"
            // this back into `.onAppear` — that reintroduces the silent-failure bug.
            .task(id: skin.id) {
                if skin.isSpriteBased && SpriteSheetStore.shared.load(skin) == nil {
                    onLoadFailure(skin)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if skin.isSpriteBased, let loaded = SpriteSheetStore.shared.load(skin) {
            SpriteMascotView(loaded: loaded, status: status, sessionCount: sessionCount)
        } else {
            CatView(status: status, sessionCount: sessionCount)
        }
    }
}
