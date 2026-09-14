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
/// `@MainActor` is explicit rather than inferred. On Swift 6.3 (the toolchain this
/// is developed on) SwiftUI's `View` members are main-actor isolated by default, so
/// calling `SpriteSheetStore.shared` — which is `@MainActor` — compiles without it.
/// On the toolchain shipping with macOS 14, the deployment target and what CI
/// builds on, that inference does not happen and the same call is an error. The
/// annotation is a no-op at runtime (these bodies only ever run on the main actor)
/// and it is what makes the file build on both.
@MainActor
struct MascotView: View {
    let skin: MascotSkin
    /// Drives the sprite/hand-drawn pose (`SpriteMascotView` keys its animation on it,
    /// `CatView` its posture). Kept distinct from `indicator`, which drives only the
    /// badge — the pose has its own display priorities (waiting outranks working).
    let status: AggregateStatus
    /// The single source the badge renders from — see `SessionStore.indicator`.
    let indicator: MascotIndicator
    /// Sizes for the island. Unset means the floating mascot's canvas and scale.
    var drawingSize: CGSize?
    var canvasSize: CGSize?
    var showsBadge: Bool = true
    /// When the current state began — see `SpriteMascotView.since`.
    var since: Date?
    /// Called when a sprite skin could not be loaded, so the app can report it.
    var onLoadFailure: (MascotSkin) -> Void = { _ in }

    /// Explains the badge count to a hovering mouse, reusing the same strings the
    /// menu-bar icon's own tooltip already shows for `AggregateStatus` — no new
    /// catalog keys, just a second place those five map to. The island's short
    /// menu is a non-key SwiftUI view, so AppKit may not surface `.help(...)` there;
    /// the floating cat and the full menu both do.
    private var mascotHelp: String {
        switch status {
        case .working(let n): return L10n.f("menubar.working", "working: %d", n)
        case .waiting(let n): return L10n.f("menubar.waiting", "waiting: %d", n)
        case .sleeping: return L10n.t("menubar.asleep", "asleep")
        case .done: return L10n.t("menubar.done", "done")
        case .problem: return L10n.t("menubar.problem", "problem")
        }
    }

    var body: some View {
        content
            .help(mascotHelp)
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
            SpriteMascotView(loaded: loaded, status: status, indicator: indicator,
                             showsBadge: showsBadge,
                             drawingSize: drawingSize, canvasSize: canvasSize,
                             since: since)
        } else {
            fallback
        }
    }

    /// The emergency render. `CatView` has no `showsBadge` of its own — it draws
    /// `MascotBadge` unconditionally — so the badge is suppressed here, in the branch
    /// where `MascotView` already knows about `showsBadge`, rather than by changing
    /// `CatView`'s contract (the floating cat's badge has to stay). `MascotBadge`
    /// draws nothing for the `.sleeping` tone (see its body), so passing a sleeping
    /// indicator reliably switches it off — the same technique `SkinPickerView` uses
    /// for its 34pt previews.
    @ViewBuilder
    private var fallback: some View {
        let badge = showsBadge ? indicator
            : MascotIndicator(tone: .sleeping, count: 0, crashedMarker: false)
        let cat = CatView(status: status, indicator: badge)
        if let canvasSize {
            // `CatView` draws itself on a square `MascotLayout.canvasSize` canvas
            // (128pt) — without shrinking, it would look like a cropped fragment in a
            // 32pt island wing. The same technique as `SkinPickerView`'s
            // (`.scaleEffect(previewSize / MascotLayout.canvasSize)`), only the size
            // comes from the `canvasSize` already passed in. Scaled by the smaller
            // side, not by height: the fallback `spriteSize` from `geometry()` (24×24)
            // gives a non-square 24×32 canvas, and scaling by height would stretch the
            // square cat to 32×32 — 4pt wider than the frame on each side, unnoticed
            // today only because `wingPadding` (8pt) absorbs it. Scaling by the smaller
            // side keeps the cat inside the frame by construction rather than by a
            // coincidence of constants. When `canvasSize` is unset (the floating cat)
            // this branch does not run and behaviour is unchanged to the pixel.
            cat
                .scaleEffect(min(canvasSize.width, canvasSize.height) / MascotLayout.canvasSize)
                .frame(width: canvasSize.width, height: canvasSize.height)
        } else {
            cat
        }
    }
}
