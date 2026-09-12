import Foundation

/// The bridge from a Claude Code session to the exact chat in the desktop Claude
/// app.
///
/// The desktop app keeps one JSON record per Claude Code session under
/// `~/Library/Application Support/Claude/claude-code-sessions/<org>/<user>/local_<id>.json`.
/// Each record has two ids: `sessionId` (`local_…`, the app's own) and
/// `cliSessionId` — the id Claude Code itself uses, which is exactly what the hooks
/// hand CodeCat. The app also registers `claude://code/continue?session=<local id>`,
/// which opens that one session. Match the record, build the URL, open it.
///
/// Pure file reading with an injectable root, so the whole thing is testable on a
/// temporary directory. Nothing here is cached: the index is consulted at click
/// time only (see `SystemJumpExecutor`), never while a row is being drawn, and a
/// scan is a few hundred small files at most.
public enum DesktopSessionIndex {

    /// Bundle identifier of the desktop Claude app — the host whose sessions this
    /// index can aim at.
    public static let desktopBundleID = "com.anthropic.claudefordesktop"

    /// Where the desktop app keeps its records by default.
    public static var defaultRoot: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claude/claude-code-sessions", isDirectory: true)
    }

    /// The desktop app's own id (`local_…`) for the session Claude Code knows as
    /// `cliSessionID`, or nil when no record mentions it — a CLI session that was
    /// never opened in the app, or a root that does not exist.
    public static func localSessionID(forCLISession cliSessionID: String,
                                      root: URL = defaultRoot) -> String? {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root,
                                         includingPropertiesForKeys: [.isRegularFileKey],
                                         options: [.skipsHiddenFiles]) else { return nil }
        for case let url as URL in walker {
            let name = url.lastPathComponent
            guard name.hasPrefix("local_"), name.hasSuffix(".json") else { continue }
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let record = object as? [String: Any],
                  record["cliSessionId"] as? String == cliSessionID
            else { continue }
            if let own = record["sessionId"] as? String, own.hasPrefix("local_") {
                return own
            }
            return String(name.dropLast(".json".count))
        }
        return nil
    }

    /// The URL that opens one session in the desktop app. `source` is what the app
    /// records as the origin of the link; naming CodeCat there costs nothing and
    /// makes the app's own logs legible.
    public static func deepLink(localSessionID: String) -> URL {
        var components = URLComponents()
        components.scheme = "claude"
        components.host = "code"
        components.path = "/continue"
        components.queryItems = [
            URLQueryItem(name: "session", value: localSessionID),
            URLQueryItem(name: "source", value: "codecat"),
        ]
        return components.url!
    }
}
