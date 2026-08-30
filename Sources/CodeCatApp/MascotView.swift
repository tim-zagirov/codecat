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
        if skin.isSpriteBased, let loaded = SpriteSheetStore.shared.load(skin) {
            SpriteMascotView(loaded: loaded, status: status, sessionCount: sessionCount)
        } else {
            CatView(status: status, sessionCount: sessionCount)
                .onAppear {
                    if skin.isSpriteBased { onLoadFailure(skin) }
                }
        }
    }
}
