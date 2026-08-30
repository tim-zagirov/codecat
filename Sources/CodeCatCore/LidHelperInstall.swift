import Foundation

/// Pure helpers for the closed-lid-mode one-time installer flow (see
/// `LidSleepController` and `scripts/install-lid-mode.sh`). Kept free of `Process`,
/// `NSAlert`, and dispatch-queue concerns so the string-building and result
/// classification can be unit tested without ever shelling out to `osascript`; the
/// app (`AppState`) owns actually running the process and presenting the result.
public enum LidHelperInstall {
    /// Result of one attempt to run the installer via
    /// `osascript ... with administrator privileges`.
    public enum Outcome: Equatable {
        case success
        /// The user dismissed/cancelled the administrator password prompt.
        case cancelled
        /// The script ran but exited non-zero for a reason other than cancellation.
        /// `detail` is meant to be shown to the user, e.g. "код завершения 1: ...".
        case failed(detail: String)
    }

    /// Builds the argument to `osascript -e` that runs `bash <scriptPath>` with
    /// administrator privileges.
    ///
    /// Two layers need escaping here, independently:
    /// - `scriptPath` is wrapped in single quotes for the *shell* command
    ///   (`bash '<path>'`), so a path containing spaces is passed as one argument.
    ///   Any literal `'` in the path is escaped the standard POSIX way
    ///   (`'\''`: close the quote, an escaped quote, reopen the quote).
    /// - The resulting shell command is then embedded in an AppleScript string
    ///   literal (`do shell script "..."`), so backslashes and double quotes in it
    ///   must be escaped for *AppleScript*, not the shell.
    ///
    /// Without both layers, a bundle path containing a space runs the wrong
    /// command, and a path containing `"` or `\` breaks out of the AppleScript
    /// string literal.
    public static func appleScript(forScriptAt scriptPath: String) -> String {
        let shellQuotedPath = "'" + scriptPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let shellCommand = "bash \(shellQuotedPath)"
        let asEscaped = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(asEscaped)\" with administrator privileges"
    }

    /// Classifies the raw exit status/combined-output of an install attempt.
    ///
    /// macOS's `do shell script ... with administrator privileges` reports a
    /// dismissed password prompt as AppleScript error -128 ("User canceled."),
    /// surfaced by `osascript` as a non-zero exit with that text in its output —
    /// that is the one non-zero case that is not a real failure.
    public static func classify(status: Int32, output: String) -> Outcome {
        guard status != 0 else { return .success }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("-128")
            || trimmed.localizedCaseInsensitiveContains("user canceled")
            || trimmed.localizedCaseInsensitiveContains("user cancelled") {
            return .cancelled
        }
        let detail = trimmed.isEmpty
            ? "код завершения \(status)"
            : "код завершения \(status): \(trimmed)"
        return .failed(detail: detail)
    }
}
