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
    let status: AggregateStatus
    let sessionCount: Int
    /// Размеры для острова. Не заданы — канва и нормировка плавающего маскота.
    var drawingSize: CGSize?
    var canvasSize: CGSize?
    var showsBadge: Bool = true
    /// Момент входа в текущее состояние — см. `SpriteMascotView.since`.
    var since: Date?
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
                             drawingSize: drawingSize, canvasSize: canvasSize,
                             since: since)
        } else {
            fallback
        }
    }

    /// Аварийная отрисовка: у `CatView` нет своего `showsBadge` — он рисует
    /// `MascotBadge` безусловно, — поэтому бейдж гасится здесь, на уровне ветки,
    /// где `MascotView` уже знает про `showsBadge`, а не правкой контракта
    /// `CatView` (у плавающего кота бейдж обязан остаться на месте). `MascotBadge`
    /// рисует себя только при `sessionCount > 0` (см. её тело), так что нулевой
    /// счётчик надёжно её выключает — тем же приёмом, каким уже пользуется
    /// `SkinPickerView` для своих превью 34pt.
    @ViewBuilder
    private var fallback: some View {
        let cat = CatView(status: status, sessionCount: showsBadge ? sessionCount : 0)
        if let canvasSize {
            // `CatView` рисует себя на квадратной канве `MascotLayout.canvasSize`
            // (128pt) — без сжатия в островном крыле высотой 32pt он показался бы
            // обрезанным фрагментом. Тот же приём, что и у `SkinPickerView`
            // (`.scaleEffect(previewSize / MascotLayout.canvasSize)`), только
            // размер берётся из уже переданного `canvasSize`. Масштаб — по меньшей
            // стороне, а не по высоте: запасной `spriteSize` из `geometry()`
            // (24×24) даёт неквадратную канву 24×32, и масштаб по высоте растянул
            // бы квадратного кота до 32×32 — на 4pt шире рамки с каждой стороны,
            // сегодня незаметно только потому, что `wingPadding` (8pt) это
            // проглатывает. Масштаб по меньшей стороне держит кота внутри рамки по
            // построению, а не по совпадению констант. Когда `canvasSize` не
            // задан (плавающий кот), эта ветка не выполняется — поведение не
            // меняется ни на пиксель.
            cat
                .scaleEffect(min(canvasSize.width, canvasSize.height) / MascotLayout.canvasSize)
                .frame(width: canvasSize.width, height: canvasSize.height)
        } else {
            cat
        }
    }
}
