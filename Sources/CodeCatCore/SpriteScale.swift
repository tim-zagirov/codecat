import Foundation

/// How much a sprite skin is magnified on the mascot canvas.
///
/// The obvious rule — fit the sprite's bounding box into a 96pt square, i.e.
/// `floor(96 / max(width, height))` — does not work here, because the packs draw
/// cats in very different proportions. LuizMelo's cats are four-legged, wide and
/// low (27x14 px), while mxmaze's kitten fills its entire 16x16 tile. Normalising
/// the *larger* side gave LuizMelo 81x42pt and mxmaze 96x96pt: one cat more than
/// twice the height of the other, which reads as two different mascot sizes rather
/// than two skins.
///
/// So height is what gets normalised — height is what the eye reads as "how big is
/// the cat" — with a cap on width so a wide sprite cannot run off the canvas.
public enum SpriteScale {

    /// The height a skin is scaled towards. The drawn cat sits ~87pt tall, but it
    /// sits *upright*; matching four-legged cats to that height would stretch them
    /// to ~160pt wide. 64pt is the compromise that keeps every skin comparable.
    public static let targetHeight = 64

    /// The widest a skin may be drawn. The canvas is `MascotLayout.canvasSize`
    /// (128pt); the remaining slack is left for the badge and the edges.
    public static let maxWidth = 120

    /// Высота, к которой нормируется облик в строке меню на экране с вырезом
    /// (`safeAreaInsets.top` = 32 pt). Меньше нельзя: на 30 pt квадратный облик
    /// mxmaze (16x16) падает до x1 — см. `SpriteScaleTests`.
    public static let islandTargetHeight = 32

    /// Предел ширины спрайта в крыле острова. Крыло перекрывает строку меню,
    /// поэтому оно не должно разрастаться ради широких четвероногих котов.
    public static let islandMaxWidth = 60

    /// Integer magnification for a skin whose union bounding box is
    /// `boundsWidth` x `boundsHeight` pixels. Never returns less than 1: a sprite
    /// too large to fit is drawn at 1x rather than vanishing.
    ///
    /// Нормировка задаётся параметрами, потому что мест теперь два: канва
    /// плавающего маскота (значения по умолчанию — 64/120) и строка меню
    /// (`islandTargetHeight`/`islandMaxWidth`). Значения по умолчанию обязаны
    /// оставаться прежними: от них зависит вид плавающего кота.
    public static func factor(boundsWidth: Int,
                              boundsHeight: Int,
                              targetHeight: Int = SpriteScale.targetHeight,
                              maxWidth: Int = SpriteScale.maxWidth) -> Int {
        guard boundsWidth > 0, boundsHeight > 0 else { return 1 }
        return max(1, min(targetHeight / boundsHeight, maxWidth / boundsWidth))
    }
}
