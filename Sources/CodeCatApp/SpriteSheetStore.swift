import AppKit
import CoreGraphics
import ImageIO
import CodeCatCore

/// A skin whose sheets have been read, measured and cached.
struct LoadedSkin {
    let skin: MascotSkin
    /// Integer magnification, from `SpriteScale`.
    let scale: Int
    /// The union of every frame's opaque-pixel bounding box, in sheet pixels,
    /// expressed relative to a single frame's origin. One rectangle for the whole
    /// skin — deliberately not one per animation: LuizMelo's sleeping cat is 22x5
    /// while its working cat is 21x14, so a per-animation crop would jolt the cat
    /// around the canvas every time the state changed.
    let bounds: CGRect

    /// On-screen size of the drawing, in points.
    var drawingSize: CGSize {
        CGSize(width: bounds.width * CGFloat(scale), height: bounds.height * CGFloat(scale))
    }
}

/// Loads sprite sheets out of the app bundle and keeps them in memory. Everything
/// together is under 120 KB, so nothing is ever evicted.
///
/// Every failure path returns nil rather than throwing: the caller's answer is
/// always the same — fall back to the drawn cat and say so once.
///
/// `@MainActor`: every caller today already runs on the main actor (SwiftUI view
/// bodies, and the `.task` in `MascotView`, which runs on a `@MainActor` view), so
/// there is no live data race. The annotation documents that invariant rather than
/// changing behaviour — without it, `swift build -Xswiftc -strict-concurrency=complete`
/// flags `shared` as a non-concurrency-safe static property, the one warning in the
/// whole package.
@MainActor
final class SpriteSheetStore {

    static let shared = SpriteSheetStore()

    private var sheets: [String: CGImage] = [:]      // keyed by "<directory>/<sheet>"
    private var loaded: [String: LoadedSkin] = [:]   // keyed by skin id
    private var failed: Set<String> = []             // skin ids already known to be broken

    /// Directory that holds `Skins/`, resolved once.
    ///
    /// Deliberately never touches `Bundle.module`: the generated
    /// `resource_bundle_accessor.swift` calls `fatalError` when neither of its two
    /// candidate paths exists, and that path is reachable in production — if the
    /// `Skins` assets are ever missing from a shipped `.app` (e.g. a packaging
    /// mistake on a machine other than the one that built it), touching
    /// `Bundle.module` would hard-crash the app at launch instead of letting the
    /// existing nil-handling fall back to the drawn cat with an alert
    /// (`AppState.reportSkinLoadFailure`). `make app` guards against that mistake at
    /// build time (see the Makefile's post-copy check, driven by `SkinAssetsTests`),
    /// but this resolver does not rely on that guard having run.
    ///
    /// Instead the two layouts `Bundle.module` would have found are probed by hand,
    /// and this returns nil — not a crash — when neither exists, so every caller's
    /// existing nil-handling takes over:
    /// - `Bundle.main.resourceURL/Skins`: the installed `.app`, where assets were
    ///   copied into `Contents/Resources/Skins` and signed as part of the bundle.
    /// - `Bundle.main.bundleURL/CodeCat_CodeCatApp.bundle/Skins`: for a bare
    ///   SwiftPM executable (`swift run`, or any future test host), `Bundle.main`
    ///   has no real bundle structure, so Foundation treats the directory holding
    ///   the executable as its `bundleURL` — the same directory SwiftPM's build
    ///   output places `CodeCat_CodeCatApp.bundle` in (confirmed by inspecting
    ///   `.build/<triple>/debug/`), so this is exactly the layout the generated
    ///   accessor's own `mainPath` resolves to, without hardcoding any absolute path.
    private static let skinsRoot: URL? = {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Skins"),
            Bundle.main.bundleURL.appendingPathComponent("CodeCat_CodeCatApp.bundle/Skins"),
        ]
        for case let candidate? in candidates where isDirectory(candidate) {
            return candidate
        }
        return nil
    }()

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// Reads, measures and caches a skin. Returns nil if any declared sheet is
    /// missing or unreadable, or if the skin turns out to be fully transparent.
    func load(_ skin: MascotSkin) -> LoadedSkin? {
        guard skin.isSpriteBased else { return nil }
        if let cached = loaded[skin.id] { return cached }
        if failed.contains(skin.id) { return nil }

        var union: CGRect = .null
        for animation in skin.animations.values {
            for frame in animation.frames {
                guard let sheet = sheet(named: frame.sheet, of: skin),
                      let rect = frameRect(frame, of: skin, in: sheet),
                      let opaque = opaqueBounds(of: sheet, in: rect) else {
                    failed.insert(skin.id)
                    return nil
                }
                union = union.union(opaque)
            }
        }
        guard !union.isNull, union.width >= 1, union.height >= 1 else {
            failed.insert(skin.id)
            return nil
        }
        let result = LoadedSkin(
            skin: skin,
            scale: SpriteScale.factor(boundsWidth: Int(union.width), boundsHeight: Int(union.height)),
            bounds: union)
        loaded[skin.id] = result
        return result
    }

    /// The cropped, unscaled image for one frame. Cropping uses the skin-wide
    /// `bounds`, so the cat keeps its place across states while motion *within* an
    /// animation is preserved in full.
    func image(for frame: SpriteFrame, of skin: MascotSkin, cropping bounds: CGRect) -> CGImage? {
        guard let sheet = sheet(named: frame.sheet, of: skin),
              let rect = frameRect(frame, of: skin, in: sheet) else { return nil }
        let crop = CGRect(x: rect.origin.x + bounds.origin.x,
                          y: rect.origin.y + bounds.origin.y,
                          width: bounds.width, height: bounds.height)
        return sheet.cropping(to: crop)
    }

    // MARK: - Sheets

    private func sheet(named name: String, of skin: MascotSkin) -> CGImage? {
        guard let directory = skin.directory else { return nil }
        let key = "\(directory)/\(name)"
        if let cached = sheets[key] { return cached }
        // `.copy("Skins")` keeps the directory tree, so the sheet sits at
        // <skinsRoot>/<directory>/<name>. `Bundle`'s `url(forResource:withExtension:)`
        // treats a whole "Skins/<key>" string as a single resource *name* rather than
        // a subdirectory path and fails to find it, so the lookup goes through the
        // resolved skins root URL and appends the path components directly.
        guard let skinsRoot = Self.skinsRoot else { return nil }
        let url = skinsRoot.appendingPathComponent(key)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        sheets[key] = image
        return image
    }

    /// Where a frame sits in its sheet. The column count comes from the image's real
    /// width, never from declared data — see `SpriteFrame`.
    private func frameRect(_ frame: SpriteFrame, of skin: MascotSkin, in sheet: CGImage) -> CGRect? {
        let size = skin.frameSize
        guard size > 0 else { return nil }
        let columns = sheet.width / size
        let rows = sheet.height / size
        guard columns > 0, rows > 0, frame.index >= 0, frame.index < columns * rows else { return nil }
        return CGRect(x: CGFloat((frame.index % columns) * size),
                      y: CGFloat((frame.index / columns) * size),
                      width: CGFloat(size), height: CGFloat(size))
    }

    // MARK: - Measuring

    /// Bounding box of the non-transparent pixels inside `rect`, returned relative to
    /// `rect`'s own origin. Nil when the region is fully transparent.
    ///
    /// The sheet is drawn into a known 8-bit RGBA buffer rather than reading the
    /// PNG's own bytes, so the alpha layout is fixed and does not depend on how the
    /// file happens to be encoded.
    private func opaqueBounds(of sheet: CGImage, in rect: CGRect) -> CGRect? {
        guard let tile = sheet.cropping(to: rect) else { return nil }
        let width = tile.width, height = tile.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
                data: &pixels, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(tile, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 8 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // A `CGBitmapContext`'s buffer is stored top-down — the same addressing
        // `cropping(to:)` uses — so the scan's row indices are already in the
        // right space and need no conversion.
        return CGRect(x: CGFloat(minX), y: CGFloat(minY),
                      width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1))
    }
}
