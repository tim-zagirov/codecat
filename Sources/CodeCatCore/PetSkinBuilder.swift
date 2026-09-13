import Foundation

/// Turns a pet in the Codex pet format into a `MascotSkin`.
///
/// The sheet is a fixed 8-column × 9-row grid; timing is not in the file, so the
/// rates below approximate the per-frame millisecond tables the Codex app uses,
/// one uniform rate per row. Upstream holds every row's last frame about twice
/// as long as the others; that hold is reproduced by listing the frame twice,
/// which keeps `SpritePhase` free of per-frame durations.
public enum PetSkinBuilder {

    public static let columns = 8
    public static let rows = 9

    /// Imported ids live in their own namespace. Persisted — never rename.
    public static let idPrefix = "pet:"

    /// The nine rows, in the order the format fixes them. Rows 1–3 are drag
    /// locomotion and a greeting that CodeCat has no state for.
    public enum Row: Int {
        case idle = 0, runningRight, runningLeft, waving, jumping, failed, waiting, running, review
    }

    /// One line, for every imported pet: the format carries no licence, so the
    /// only honest statement is that the author's own terms apply.
    public static var importedTerms: String {
        L10n.t("skin.imported.terms", "Imported pet — its author's own terms apply.")
    }

    /// Nil when the sheet is not an 8×9 grid.
    public static func skin(manifest: PetManifest, directory: URL,
                            sheetWidth: Int, sheetHeight: Int) -> MascotSkin? {
        guard sheetWidth > 0, sheetHeight > 0,
              sheetWidth % columns == 0, sheetHeight % rows == 0,
              sheetWidth % 48 == 0, sheetHeight % 52 == 0 else { return nil }
        let sheet = manifest.spritesheetPath

        func frames(_ row: Row, count: Int) -> [SpriteFrame] {
            var result = (0..<count).map { SpriteFrame(sheet: sheet, index: row.rawValue * columns + $0) }
            result.append(result[count - 1])   // the longer hold on the last frame
            return result
        }
        func loop(_ row: Row, count: Int, fps: Double) -> SpriteAnimation {
            SpriteAnimation(frames: frames(row, count: count), framesPerSecond: fps)
        }

        return MascotSkin(
            id: idPrefix + manifest.id,
            name: manifest.displayName,
            author: manifest.displayName,
            license: .authorTerms(summary: importedTerms),
            sourceURL: directory.path,
            location: .external(directory),
            frameWidth: sheetWidth / columns,
            frameHeight: sheetHeight / rows,
            bundled: false,
            note: manifest.description,
            animations: [
                .sleeping: loop(.idle, count: 6, fps: 5),
                .working: loop(.running, count: 6, fps: 8),
                .waiting: loop(.waiting, count: 6, fps: 6.5),
                // Work is over: a couple of jumps, then the pet settles into its
                // "review" loop — the same shape as the built-ins' stretch-then-rest.
                .done: SpriteAnimation(phases: [
                    SpritePhase(frames: frames(.jumping, count: 5), framesPerSecond: 7, repeats: 2),
                    SpritePhase(frames: frames(.review, count: 6), framesPerSecond: 6.5),
                ]),
                .problem: loop(.failed, count: 8, fps: 7),
            ])
    }
}
