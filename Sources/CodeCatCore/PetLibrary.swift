import Foundation

/// Finds pets in the Codex pet format on disk. Pure directory walking with an
/// injected image-size reader (that is ImageIO, which belongs to the app layer),
/// so the whole thing runs against a temporary directory in tests.
public enum PetLibrary {

    /// A folder that looked like a pet and was not usable, with a reason in plain
    /// words for the log.
    public struct Report: Equatable, Sendable {
        public let folder: URL
        public let reason: String
        public init(folder: URL, reason: String) {
            self.folder = folder
            self.reason = reason
        }
    }

    public struct Result: Equatable, Sendable {
        public let skins: [MascotSkin]
        public let skipped: [Report]
        public init(skins: [MascotSkin], skipped: [Report]) {
            self.skins = skins
            self.skipped = skipped
        }
    }

    /// CodeCat's own folder first, then the Codex one — `$CODEX_HOME/pets` when the
    /// variable is set, `~/.codex/pets` otherwise, exactly as the hatch-pet skill
    /// resolves it.
    public static func defaultRoots(environment: [String: String] = ProcessInfo.processInfo.environment,
                                    home: URL = CodeCatPaths.home) -> [URL] {
        let codexHome = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".codex", isDirectory: true)
        return [CodeCatPaths.petsRoot, codexHome.appendingPathComponent("pets", isDirectory: true)]
    }

    /// Every immediate subdirectory of every root that holds a `pet.json`. Roots
    /// are searched in order and the first pet with a given id wins. A folder
    /// without a manifest is not a pet and is passed over silently; a folder with
    /// one that cannot be used is reported.
    public static func discover(roots: [URL],
                                sheetSize: (URL) -> (width: Int, height: Int)?) -> Result {
        let fm = FileManager.default
        var seen = Set<String>()
        var skins: [MascotSkin] = []
        var skipped: [Report] = []

        for root in roots {
            guard let entries = try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            else { continue }
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                else { continue }
                // Rebuilt from `root` rather than taken from `entry.path`: on
                // macOS, `contentsOfDirectory` silently resolves `/var` (and a
                // few other special directories) to `/private/var`, which would
                // otherwise leak a symlink resolution `PetLibrary` never asked
                // for and never wants — the folder path shown to the user must
                // stay the one they know.
                let folder = root.appendingPathComponent(entry.lastPathComponent, isDirectory: true)
                let manifestURL = folder.appendingPathComponent("pet.json")
                guard fm.fileExists(atPath: manifestURL.path) else { continue }

                guard let data = try? Data(contentsOf: manifestURL),
                      let manifest = PetManifest.parse(data, folderName: folder.lastPathComponent) else {
                    skipped.append(Report(folder: folder, reason: "pet.json is not a JSON object"))
                    continue
                }
                let sheetURL = folder.appendingPathComponent(manifest.spritesheetPath)
                guard fm.fileExists(atPath: sheetURL.path) else {
                    skipped.append(Report(folder: folder, reason: "sheet missing: \(manifest.spritesheetPath)"))
                    continue
                }
                guard let size = sheetSize(sheetURL) else {
                    skipped.append(Report(folder: folder, reason: "sheet could not be decoded: \(manifest.spritesheetPath)"))
                    continue
                }
                guard let skin = PetSkinBuilder.skin(manifest: manifest, directory: folder,
                                                     sheetWidth: size.width, sheetHeight: size.height) else {
                    skipped.append(Report(folder: folder,
                                          reason: "sheet is \(size.width)x\(size.height), not an 8x9 grid"))
                    continue
                }
                guard seen.insert(skin.id).inserted else {
                    skipped.append(Report(folder: folder, reason: "duplicate pet id \(manifest.id) — an earlier folder wins"))
                    continue
                }
                skins.append(skin)
            }
        }
        // Tiebreak on `id`: Swift's `sort` is not stable, so two pets sharing a
        // display name could otherwise flip order between rescans depending on
        // where the standard library happened to leave them mid-sort.
        skins.sort {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        return Result(skins: skins, skipped: skipped)
    }
}
