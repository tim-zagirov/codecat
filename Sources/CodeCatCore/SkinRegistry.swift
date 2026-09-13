import Foundation

/// Every skin the picker may offer: the eight built-ins, then whatever pets were
/// found on disk. Replaces direct use of `MascotSkins.all` / `skin(withID:)` in
/// the app so an imported id resolves exactly like a built-in one — and falls
/// back exactly like one when it is gone.
public struct SkinRegistry: Equatable, Sendable {
    public let builtIn: [MascotSkin]
    public let imported: [MascotSkin]

    public init(builtIn: [MascotSkin] = MascotSkins.all, imported: [MascotSkin] = []) {
        self.builtIn = builtIn
        self.imported = imported
    }

    public var installed: [MascotSkin] { builtIn + imported }

    /// Falls back to `MascotSkins.default` for anything unknown — the same rule
    /// `MascotSkins.skin(withID:)` has always applied to the built-ins.
    public func skin(withID id: String) -> MascotSkin {
        installed.first { $0.id == id } ?? MascotSkins.default
    }

    public static func isImported(_ skin: MascotSkin) -> Bool {
        skin.id.hasPrefix(PetSkinBuilder.idPrefix)
    }
}
