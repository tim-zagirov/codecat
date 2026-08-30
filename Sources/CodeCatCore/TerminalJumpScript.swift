import Foundation

/// Builds the AppleScript that selects the terminal tab a session runs in.
///
/// Terminals are addressed by bundle id (`tell application id "..."`) rather than by
/// name, so a renamed or relocated copy still resolves, and the tty is embedded as a
/// string literal — escaped, never interpolated raw, the same discipline as
/// `LidHelperInstall.appleScript(forScriptAt:)`.
public enum TerminalJumpScript {
    /// Printed by the script when the tab was found and selected.
    public static let successMarker = "codecat-ok"
    /// Printed when no tab with that tty exists any more (the user closed it).
    public static let notFoundMarker = "codecat-notfound"

    /// Escapes a value for an AppleScript string literal. Backslashes first, then
    /// quotes: doing it the other way round would double the backslash that escaping
    /// a quote just inserted.
    public static func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    public static func script(bundleID: String, tty: String) -> String? {
        let tty = escaped(tty)
        switch bundleID {
        case "com.apple.Terminal":
            return """
            tell application id "com.apple.Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(tty)" then
                            set selected of t to true
                            set index of w to 1
                            activate
                            return "\(successMarker)"
                        end if
                    end repeat
                end repeat
            end tell
            return "\(notFoundMarker)"
            """
        case "com.googlecode.iterm2":
            return """
            tell application id "com.googlecode.iterm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(tty)" then
                                select w
                                select t
                                select s
                                activate
                                return "\(successMarker)"
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return "\(notFoundMarker)"
            """
        default:
            return nil
        }
    }
}
