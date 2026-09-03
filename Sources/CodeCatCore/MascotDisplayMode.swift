import Foundation

/// How the mascot is shown on screen. The modes are mutually exclusive: exactly one
/// is on screen at any time.
public enum MascotDisplayMode: String, CaseIterable, Sendable {
    /// A floating window the user drags with the mouse. Behaviour from the MVP.
    case floating
    /// A black slab around the physical notch of the built-in display.
    case island

    /// Installing a new version must not change the display mode by itself.
    public static let `default` = MascotDisplayMode.floating

    /// Reads the value from the settings. Anything unrecognised means the default:
    /// `UserDefaults` may hold a string from an older or a newer version.
    public static func mode(withID id: String?) -> MascotDisplayMode {
        guard let id, let mode = MascotDisplayMode(rawValue: id) else { return .default }
        return mode
    }

    /// The label shown in the interface.
    public var title: String {
        switch self {
        case .floating: return L10n.t("display.mode.floating", "Cat")
        case .island: return L10n.t("display.mode.island", "Island")
        }
    }
}
