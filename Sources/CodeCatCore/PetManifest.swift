import Foundation

/// `pet.json` of a pet in the Codex pet format. The published file has exactly
/// four string keys and nothing else — no timing, no geometry, no author, no
/// licence; those all live in the sheet's fixed 8×9 layout or in the app.
public struct PetManifest: Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let description: String?
    /// Relative to the pet's directory.
    public let spritesheetPath: String

    /// What `hatch-pet` names the sheet when the manifest does not say.
    public static let defaultSheetName = "spritesheet.webp"

    public init(id: String, displayName: String, description: String?, spritesheetPath: String) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.spritesheetPath = spritesheetPath
    }

    /// Nil only when the file is not a JSON object at all. A missing or empty
    /// key falls back: `id` to the folder name, `displayName` to the id, the sheet
    /// to `spritesheet.webp`. `description` is genuinely optional.
    public static func parse(_ data: Data, folderName: String) -> PetManifest? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else { return nil }
        func string(_ key: String) -> String? {
            guard let value = dict[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        let id = string("id") ?? folderName
        return PetManifest(id: id,
                           displayName: string("displayName") ?? id,
                           description: string("description"),
                           spritesheetPath: string("spritesheetPath") ?? defaultSheetName)
    }
}
