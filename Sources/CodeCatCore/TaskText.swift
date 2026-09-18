import Foundation

/// What the user asked this session for, reduced to the one line the session row
/// shows. Two decisions live here and nowhere else, because both the hook (which
/// trims the prompt before forwarding it) and the store (which decides whether a new
/// prompt replaces the old task) have to make them the same way.
public enum TaskText {
    /// The longest task text ever stored or sent. The row clamps by lines, not by
    /// characters — this cap is about what is held in memory and, more sharply, about
    /// the hook: a unix datagram on macOS is capped at 2 048 bytes
    /// (`net.local.dgram.maxdgram`), a `UserPromptSubmit` payload without the prompt
    /// is ~670 B, and a prompt longer than that limit makes the whole event vanish.
    /// 160 characters survive even the worst case, where every character is escaped
    /// as `\uXXXX` (160 × 6 + 670 < 2 048).
    public static let maxLength = 160

    /// A prompt shorter than this does not replace a task that is already known.
    /// Measured: of 1 012 real prompts on one machine, 28 % were 15 characters or
    /// less — "продолжай", "газ", "не открылся". They are real prompts, but they say
    /// nothing about what the session is doing.
    public static let minimumReplacementLength = 25

    /// Machine-written entries that share the same field as a real prompt. None of
    /// them is something a person typed, so a text that is nothing but one of these
    /// has no task in it.
    private static let machineWritten = [
        "<local-command-stdout>", "<local-command-caveat>", "<command-message>",
        "<system-reminder>", "<task-notification>", "<user-prompt-submit-hook>",
    ]

    /// Placeholders Claude Code writes in place of content it cannot put in the
    /// transcript. Removed wherever they sit; a text left empty by their removal has
    /// no task in it.
    private static let placeholders = [
        #"\[Image:[^\]]*\]"#,
        #"\[Request interrupted[^\]]*\]"#,
    ]

    /// The one line, or nil when the text holds no task at all. Applied to a raw
    /// prompt from the hook and to a raw user entry from the transcript alike, so the
    /// two paths can never disagree about what a prompt says.
    public static func sanitized(_ raw: String) -> String? {
        var text = raw
        if machineWritten.contains(where: { text.contains($0) && !text.contains("<command-name>") } ) {
            return nil
        }
        // A typed slash command reaches the transcript wrapped in tags. What the user
        // typed is the command and its arguments; the rest of the wrapper is markup.
        if text.contains("<command-name>") {
            let name = tagged("command-name", in: text) ?? ""
            let args = tagged("command-args", in: text) ?? ""
            text = "\(name) \(args)"
        }
        for pattern in placeholders {
            text = text.replacingOccurrences(of: pattern, with: " ",
                                             options: .regularExpression)
        }
        let ribbon = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !ribbon.isEmpty else { return nil }
        return capped(ribbon)
    }

    /// Whether `candidate` should become the session's task, given what it already
    /// has. See `minimumReplacementLength`: a short follow-up carries the
    /// conversation, not the task, and must not overwrite it — but with no task yet,
    /// anything the user said beats saying nothing.
    public static func replaces(current: String?, with candidate: String) -> Bool {
        guard let current, !current.isEmpty else { return true }
        return candidate.count >= minimumReplacementLength
    }

    /// The contents of `<tag>…</tag>`, or nil.
    private static func tagged(_ tag: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(tag)>"),
              let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex)
        else { return nil }
        let inner = text[open.upperBound..<close.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return inner.isEmpty ? nil : inner
    }

    /// Cut to `maxLength` including the ellipsis, on a word boundary when there is
    /// one. A single run longer than the cap — a path, a URL, a pasted token — has no
    /// boundary to respect and is cut by character rather than thrown away.
    private static func capped(_ text: String) -> String {
        guard text.count > maxLength else { return text }
        let head = text.prefix(maxLength - 1)
        let body: Substring
        if let lastSpace = head.lastIndex(of: " ") {
            body = head[head.startIndex..<lastSpace]
        } else {
            body = head
        }
        return body.trimmingCharacters(in: .whitespaces) + "…"
    }
}
