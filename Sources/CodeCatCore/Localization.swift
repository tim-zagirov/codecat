import Foundation

/// Every user-visible string in CodeCat, looked up by key with its English text
/// written at the call site.
///
/// **Why `.strings` and not `.xcstrings`.** A string catalog is compiled by
/// Xcode's build system; CodeCat is a SwiftPM package assembled into a bundle by
/// the Makefile, with no Xcode project anywhere in the build. `.strings` files are
/// what that build can actually produce and sign — see `Resources/en.lproj` and
/// `Resources/ru.lproj`, copied into `Contents/Resources` by `make bundle`.
///
/// **Why the English text is passed in at every call.** `localizedString` returns
/// `value` when it cannot find the key, so a build that never assembled the
/// `.lproj` directories — `swift run`, the test bundle, a packaging mistake —
/// shows real English rather than a raw key like `menu.quit`. That is the same
/// reasoning as `SpriteSheetStore.skinsRoot`: a missing resource degrades, it does
/// not disfigure the UI or crash.
///
/// **Which bundle.** `Bundle.main` — the `.app`, whose `Contents/Resources` holds
/// the `.lproj` directories. `Bundle.module` is deliberately avoided here for the
/// reason recorded in `Skins/CREDITS.md`: its generated accessor traps when the
/// bundle is missing.
///
/// Diagnostic text is *not* routed through here on purpose. The log
/// (`DiagnosticLog`, the hook's stderr) is written in English unconditionally: it
/// exists to be pasted into a bug report, and a log whose language depends on the
/// reporter's Mac is harder to read, not easier.
public enum L10n {

    /// A plain string.
    public static func t(_ key: String, _ english: String) -> String {
        Bundle.main.localizedString(forKey: key, value: english, table: nil)
    }

    /// A string with `%@`/`%d` placeholders. The format comes from the catalog, so
    /// a translation is free to reorder its arguments with `%1$@`-style indices.
    public static func f(_ key: String, _ english: String, _ arguments: CVarArg...) -> String {
        String(format: t(key, english), arguments: arguments)
    }
}
