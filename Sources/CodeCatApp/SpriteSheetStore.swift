import AppKit
import CoreGraphics
import ImageIO
import CodeCatCore

/// A skin whose sheets have been read, measured and cached.
struct LoadedSkin {
    let skin: MascotSkin
    /// Magnification from `SpriteScale.scale`: an integer for everything that fits
    /// (all built-ins, and any pet whose pitch was recovered), a fraction below 1
    /// for a sheet that had to be shrunk.
    let scale: Double
    /// The union of every frame's opaque-pixel bounding box, in sheet pixels,
    /// expressed relative to a single frame's origin. One rectangle for the whole
    /// skin — deliberately not one per animation: LuizMelo's sleeping cat is 22x5
    /// while its working cat is 21x14, so a per-animation crop would jolt the cat
    /// around the canvas every time the state changed.
    let bounds: CGRect

    /// On-screen size of the drawing, in points.
    var drawingSize: CGSize {
        CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }

    /// The drawing size under a different normalisation — for the island, where the
    /// menu bar is only 32 pt. `scale` was computed at load time for the floating
    /// mascot's canvas, so the scale here is recomputed from the same measured bounds.
    func drawingSize(targetHeight: Int, maxWidth: Int) -> CGSize {
        let scale = SpriteScale.scale(boundsWidth: Int(bounds.width),
                                      boundsHeight: Int(bounds.height),
                                      targetHeight: targetHeight,
                                      maxWidth: maxWidth)
        return CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }
}

/// Loads sprite sheets and keeps them in memory.
///
/// Built-in sheets ship in the app bundle, are tiny (everything together is
/// under 120 KB), and stay cached forever. Imported pets are a different shape
/// entirely: a canonical pet sheet is 1536×1872, and there can be any number of
/// them on disk. Their entries are dropped on every rescan by `forgetImported()`
/// rather than kept forever, so the picker session's memory use stays bounded
/// by "however many pets you looked at since the panel last opened", not by
/// "however many pets you have ever hatched".
///
/// Every failure path returns nil rather than throwing: the caller's answer is
/// always the same — fall back to the drawn cat and say so once.
///
/// `@MainActor`: every caller today already runs on the main actor (SwiftUI view
/// bodies, and the `.task` in `MascotView`, which runs on a `@MainActor` view), so
/// there is no live data race. The annotation documents that invariant rather than
/// changing behaviour — without it, `swift build -Xswiftc -strict-concurrency=complete`
/// flags `shared` as a non-concurrency-safe static property.
@MainActor
final class SpriteSheetStore {

    static let shared = SpriteSheetStore()

    /// A decoded sheet and the cell size that applies to *this* image — smaller
    /// than the skin's declared cell when the sheet was reduced by its pixel pitch.
    private struct Sheet {
        let image: CGImage
        let frameWidth: Int
        let frameHeight: Int
    }
    private var sheets: [String: Sheet] = [:]        // keyed by "<location>/<sheet>"
    private var loaded: [String: LoadedSkin] = [:]   // keyed by skin id
    private var failed: Set<String> = []             // skin ids already known to be broken
    private var assetsPresent: [String: Bool] = [:]  // keyed by skin id, see hasAssets(for:)

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
    private nonisolated static let skinsRoot: URL? = {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Skins"),
            Bundle.main.bundleURL.appendingPathComponent("CodeCat_CodeCatApp.bundle/Skins"),
        ]
        for case let candidate? in candidates where isDirectory(candidate) {
            return candidate
        }
        return nil
    }()

    private nonisolated static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// Whether every sheet this skin declares is present on disk.
    ///
    /// A file-existence check, not a load: this is asked once per skin to decide
    /// what the picker shows, and decoding eight PNGs to answer it would make
    /// opening the panel visibly slower. A skin that passes this and still fails to
    /// decode is handled where it always was — `load` returns nil and
    /// `AppState.reportSkinLoadFailure` reverts to the default with an alert.
    ///
    /// The answer is cached because it decides what the picker draws on every
    /// rebuild, and the set of files on disk does not change while the app runs.
    func hasAssets(for skin: MascotSkin) -> Bool {
        if let known = assetsPresent[skin.id] { return known }
        let present = Self.assetsExist(for: skin)
        assetsPresent[skin.id] = present
        return present
    }

    /// The uncached, actor-free form of `hasAssets(for:)`. It touches nothing but
    /// the file system and the resolved skins root, so `AppState.init` — which runs
    /// before any view exists and has no main-actor context to borrow — can ask the
    /// same question without hopping actors.
    nonisolated static func assetsExist(for skin: MascotSkin) -> Bool {
        guard let directory = directory(of: skin) else { return false }
        return skin.declaredSheets.allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    /// The directory holding this skin's sheets, or nil when a bundled skin's
    /// `Skins/` root cannot be found at all.
    nonisolated static func directory(of skin: MascotSkin) -> URL? {
        switch skin.location {
        case .bundled(let path): return skinsRoot?.appendingPathComponent(path)
        case .external(let url): return url
        }
    }

    /// Pixel size of an image file without decoding its pixels — what `PetLibrary`
    /// needs to know whether a sheet is an 8×9 grid.
    nonisolated static func imageSize(at url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    /// Reads, measures and caches a skin. Returns nil if any declared sheet is
    /// missing or unreadable, or if the skin turns out to be fully transparent.
    func load(_ skin: MascotSkin) -> LoadedSkin? {
        if let cached = loaded[skin.id] { return cached }
        if failed.contains(skin.id) { return nil }

        var union: CGRect = .null
        for animation in skin.animations.values {
            for frame in animation.frames {
                guard let sheet = sheet(named: frame.sheet, of: skin),
                      let rect = frameRect(frame, in: sheet),
                      let opaque = opaqueBounds(of: sheet.image, in: rect) else {
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
            scale: SpriteScale.scale(boundsWidth: Int(union.width), boundsHeight: Int(union.height)),
            bounds: union)
        loaded[skin.id] = result
        return result
    }

    /// Drops every cached entry that belongs to an imported pet, from all four
    /// caches.
    ///
    /// Pets are the user's own files, not something CodeCat ships and controls:
    /// they get re-hatched under the same folder, or edited in place, while the
    /// app is running. A rescan has to be able to see a sheet that changed, and a
    /// sheet that failed to load once — because it was read mid-write — has to
    /// get another chance rather than staying in `failed` forever. Called
    /// unconditionally from `AppState.rescanPets()`, before that scan's registry
    /// comparison, so both cases are covered on every rescan rather than only
    /// when the registry itself changed.
    func forgetImported() {
        sheets = sheets.filter { !$0.key.hasPrefix("external:") }
        loaded = loaded.filter { !$0.key.hasPrefix(PetSkinBuilder.idPrefix) }
        failed = failed.filter { !$0.hasPrefix(PetSkinBuilder.idPrefix) }
        assetsPresent = assetsPresent.filter { !$0.key.hasPrefix(PetSkinBuilder.idPrefix) }
    }

    /// The cropped, unscaled image for one frame. Cropping uses the skin-wide
    /// `bounds`, so the cat keeps its place across states while motion *within* an
    /// animation is preserved in full.
    func image(for frame: SpriteFrame, of skin: MascotSkin, cropping bounds: CGRect) -> CGImage? {
        guard let sheet = sheet(named: frame.sheet, of: skin),
              let rect = frameRect(frame, in: sheet) else { return nil }
        let crop = CGRect(x: rect.origin.x + bounds.origin.x,
                          y: rect.origin.y + bounds.origin.y,
                          width: bounds.width, height: bounds.height)
        return sheet.image.cropping(to: crop)
    }

    // MARK: - Sheets

    private func sheet(named name: String, of skin: MascotSkin) -> Sheet? {
        let key = "\(skin.location.cacheKey)/\(name)"
        if let cached = sheets[key] { return cached }
        // `.copy("Skins")` keeps the directory tree, so the sheet sits at
        // <skinsRoot>/<directory>/<name>. `Bundle`'s `url(forResource:withExtension:)`
        // treats a whole "Skins/<key>" string as a single resource *name* rather than
        // a subdirectory path and fails to find it, so the lookup goes through the
        // resolved skins root URL and appends the path components directly.
        guard let directory = Self.directory(of: skin) else { return nil }
        let url = directory.appendingPathComponent(name)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let sheet = Self.reducedIfPixelArt(Sheet(image: image, frameWidth: skin.frameWidth,
                                                 frameHeight: skin.frameHeight),
                                           external: skin.location.bundledPath == nil)
        sheets[key] = sheet
        return sheet
    }

    /// An external sheet drawn as upscaled pixel art is brought back to its native
    /// size, so it renders through the same integer magnification as the built-ins.
    /// The pitch is read off the first cell (frame 0 — the format's still frame,
    /// which is never empty); a cell that is not pixel art leaves the sheet as is.
    private static func reducedIfPixelArt(_ sheet: Sheet, external: Bool) -> Sheet {
        guard external,
              let cell = pixels(of: sheet.image, in: CGRect(x: 0, y: 0, width: sheet.frameWidth,
                                                            height: sheet.frameHeight)),
              let pitch = PixelPitch.detect(rows: cell),
              sheet.image.width % pitch == 0, sheet.image.height % pitch == 0,
              let reduced = sample(sheet.image, every: pitch) else { return sheet }
        return Sheet(image: reduced, frameWidth: sheet.frameWidth / pitch,
                     frameHeight: sheet.frameHeight / pitch)
    }

    /// Nearest-neighbour reduction by an exact integer: one device pixel out of
    /// every `pitch × pitch` block, which for true pixel art is lossless.
    private static func sample(_ image: CGImage, every pitch: Int) -> CGImage? {
        let width = image.width / pitch, height = image.height / pitch
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Draws `rect` into a fresh 8-bit premultiplied RGBA buffer — the one
    /// recipe `pixels(of:in:)` and `opaqueBounds(of:in:)` both need, pulled out
    /// so it exists in exactly one place instead of two that could quietly drift
    /// apart (a different `bitmapInfo`, colour space, or row order between them).
    ///
    /// The context is created and drawn into from *inside*
    /// `withUnsafeMutableBytes`'s closure, not by handing `CGContext` a pointer
    /// obtained with `&bytes` the way both call sites used to: `&array` as a
    /// call argument is only guaranteed valid for the duration of that one call,
    /// but `CGContext(data:...)` keeps the pointer and writes through it later,
    /// when `context.draw` runs — after the initializer that took `&bytes` has
    /// already returned. That happened to work, but the language does not
    /// promise it. Doing the create-and-draw inside the closure keeps the
    /// pointer's use within the span Swift actually guarantees it for.
    private static func rgbaBytes(of image: CGImage,
                                  in rect: CGRect) -> (bytes: [UInt8], width: Int, height: Int)? {
        guard let tile = image.cropping(to: rect) else { return nil }
        let width = tile.width, height = tile.height
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drew: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(tile, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }
        return (bytes, width, height)
    }

    /// The RGBA pixels of `rect`, one packed `UInt32` each, row-major, top-down.
    private static func pixels(of image: CGImage, in rect: CGRect) -> [[UInt32]]? {
        guard let (bytes, width, height) = rgbaBytes(of: image, in: rect) else { return nil }
        return (0..<height).map { y in
            (0..<width).map { x in
                let i = (y * width + x) * 4
                return UInt32(bytes[i]) << 24 | UInt32(bytes[i + 1]) << 16
                     | UInt32(bytes[i + 2]) << 8 | UInt32(bytes[i + 3])
            }
        }
    }

    /// Where a frame sits in its sheet. The column count comes from the image's real
    /// width, never from declared data — see `SpriteFrame`.
    private func frameRect(_ frame: SpriteFrame, in sheet: Sheet) -> CGRect? {
        let w = sheet.frameWidth, h = sheet.frameHeight
        guard w > 0, h > 0 else { return nil }
        let columns = sheet.image.width / w
        let rows = sheet.image.height / h
        guard columns > 0, rows > 0, frame.index >= 0, frame.index < columns * rows else { return nil }
        return CGRect(x: CGFloat((frame.index % columns) * w),
                      y: CGFloat((frame.index / columns) * h),
                      width: CGFloat(w), height: CGFloat(h))
    }

    // MARK: - Measuring

    /// Bounding box of the non-transparent pixels inside `rect`, returned relative to
    /// `rect`'s own origin. Nil when the region is fully transparent.
    ///
    /// The sheet is drawn into a known 8-bit RGBA buffer rather than reading the
    /// PNG's own bytes, so the alpha layout is fixed and does not depend on how the
    /// file happens to be encoded.
    private func opaqueBounds(of sheet: CGImage, in rect: CGRect) -> CGRect? {
        guard let (pixels, width, height) = Self.rgbaBytes(of: sheet, in: rect) else { return nil }

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
