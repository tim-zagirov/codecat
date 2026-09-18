import Foundation

/// Turns the agent's final message into what the row can hand the user: the first
/// line as a summary and the links in it as chips. Pure — the only question it
/// cannot answer alone, "does this path exist and is it a folder", is injected.
///
/// Measured on this machine (spec §1): one turn-ending message in ten carries a URL
/// or an absolute path, and the hosts are dev servers, GitHub, Figma and claude.ai.
public enum HandoffExtractor {
    public enum PathKind: Equatable, Sendable { case file, folder }

    /// Four is what one row of chips holds at island width without wrapping.
    public static let maxLinks = 4

    /// The real answer, from the file system. Tests inject a closure instead.
    public static func realPathKind(_ path: String) -> PathKind? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        return isDirectory.boolValue ? .folder : .file
    }

    public static func extract(from text: String, pathKind: (String) -> PathKind?) -> Handoff? {
        let mentions = self.mentions(in: text)
        var links: [HandoffLink] = []
        var seen: Set<String> = []
        for mention in mentions {
            guard links.count < maxLinks else { break }
            guard let link = link(for: mention, pathKind: pathKind),
                  seen.insert(link.id).inserted else { continue }
            links.append(link)
        }
        let summary = summary(of: text, mentions: mentions.map(\.raw))
        guard summary != nil || !links.isEmpty else { return nil }
        return Handoff(summary: summary, links: links)
    }

    // MARK: - Mentions

    private struct Mention { let raw: String; let isPath: Bool; let location: Int }

    /// `(`, `)`, `[`, `]`, quotes and whitespace end a URL: they are the characters
    /// prose and markdown put around one. `*` and `_` do not — they are legal in a
    /// URL — so markdown emphasis is stripped from the end afterwards instead.
    private static let urlPattern = try! NSRegularExpression(
        pattern: #"https?://[^\s<>()\[\]"'`]+"#)
    /// Only absolute paths under the home directory: "src/foo.ts" in prose is too
    /// ambiguous to click. The look-behind keeps a path from starting in the middle
    /// of a URL or another path.
    private static let pathPattern = try! NSRegularExpression(
        pattern: #"(?<![\w/.\-])(?:/Users/|~/)[^\s"'`<>()\[\]]+"#)
    private static let trailing: Set<Character> = [".", ",", ";", ":", "!", "?", "*", "_"]

    private static func mentions(in text: String) -> [Mention] {
        let range = NSRange(text.startIndex..., in: text)
        var found: [Mention] = []
        for (pattern, isPath) in [(urlPattern, false), (pathPattern, true)] {
            for match in pattern.matches(in: text, range: range) {
                guard let r = Range(match.range, in: text) else { continue }
                var raw = String(text[r])
                while let last = raw.last, trailing.contains(last) { raw.removeLast() }
                guard !raw.isEmpty else { continue }
                found.append(Mention(raw: raw, isPath: isPath, location: match.range.location))
            }
        }
        return found.sorted { $0.location < $1.location }
    }

    // MARK: - Links

    private static func link(for mention: Mention, pathKind: (String) -> PathKind?) -> HandoffLink? {
        if mention.isPath { return fileLink(mention.raw, pathKind: pathKind) }
        guard let url = URL(string: mention.raw), let host = url.host?.lowercased() else { return nil }
        let path = url.path
        if host == "localhost" || host == "127.0.0.1" {
            let title = url.port.map { "\(host):\($0)" } ?? host
            return HandoffLink(kind: .localhost, title: title, target: url)
        }
        if host == "github.com" || host == "www.github.com" {
            let parts = path.split(separator: "/")
            if parts.count >= 4, parts[2] == "pull" {
                return HandoffLink(kind: .pullRequest,
                                   title: L10n.f("handoff.title.pr", "PR #%@", String(parts[3])), target: url)
            }
            return HandoffLink(kind: .github, title: L10n.t("handoff.title.github", "GitHub"), target: url)
        }
        if host.hasSuffix("figma.com") {
            return HandoffLink(kind: .figma, title: L10n.t("handoff.title.figma", "Figma"), target: url)
        }
        if host == "claude.ai", path.contains("/artifact") {
            return HandoffLink(kind: .artifact, title: L10n.t("handoff.title.artifact", "Artifact"), target: url)
        }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return HandoffLink(kind: .web, title: bare, target: url)
    }

    /// The agent's own bookkeeping — transcripts, logs, caches — is never what it
    /// is handing over, however often it names those paths.
    private static let excludedPrefixes = ["~/.claude", "~/Library"].map {
        NSString(string: $0).expandingTildeInPath
    }

    private static func fileLink(_ raw: String, pathKind: (String) -> PathKind?) -> HandoffLink? {
        let path = NSString(string: raw).expandingTildeInPath
        guard !excludedPrefixes.contains(where: { path.hasPrefix($0) }),
              let kind = pathKind(path) else { return nil }
        let name = (path as NSString).lastPathComponent
        let url = URL(fileURLWithPath: path, isDirectory: kind == .folder)
        switch kind {
        case .file: return HandoffLink(kind: .file, title: name, target: url)
        case .folder: return HandoffLink(kind: .folder, title: name + "/", target: url)
        }
    }

    // MARK: - Summary

    private static let markdownNoise = try! NSRegularExpression(
        pattern: #"(\*\*|__|`|^#+\s*|^>\s*|^[-*]\s+)"#, options: [.anchorsMatchLines])

    /// The first line that says something: not a code fence, not a bullet made of a
    /// bare link, with the emphasis and heading marks removed.
    private static func summary(of text: String, mentions: [String]) -> String? {
        for rawLine in text.components(separatedBy: .newlines) {
            if rawLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") { continue }
            // Markdown links collapse to their text before anything else runs: a line
            // like "Created [PR #12](url)." should read as prose, not leak the raw
            // `[text](url)` wrapper and URL into a summary that is meant to be plain.
            let delinked = collapseMarkdownLinks(rawLine)
            var line = delinked
            for mention in mentions { line = line.replacingOccurrences(of: mention, with: "") }
            let stripped = markdownNoise.stringByReplacingMatches(
                in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "")
            let words = stripped.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard !words.isEmpty else { continue }
            // The line with its links kept, cleaned of markdown — a summary that
            // says "see localhost:4321" is still a summary.
            let clean = markdownNoise.stringByReplacingMatches(
                in: delinked, range: NSRange(delinked.startIndex..., in: delinked), withTemplate: "")
            return TaskText.sanitized(clean)
        }
        return nil
    }

    /// `[text](url)` → `text`. A markdown link whose text is itself the URL (the
    /// common case for a bare link an editor auto-linked) collapses to that URL, so
    /// the mention-removal step right after this still recognizes it as link-only.
    private static let markdownLink = try! NSRegularExpression(pattern: #"\[([^\]]*)\]\([^)]*\)"#)

    private static func collapseMarkdownLinks(_ line: String) -> String {
        markdownLink.stringByReplacingMatches(
            in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "$1")
    }
}
