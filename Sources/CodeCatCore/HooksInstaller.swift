import Foundation

/// Errors thrown while parsing or rewriting `~/.claude/settings.json`.
public enum HooksInstallerError: Error {
    case invalidJSON
    /// The value stored at `hooks.<event>` was present but not an array, so it
    /// could not be safely merged with CodeCat's hook group without risking
    /// data loss. `event` names the offending key.
    case unexpectedHooksShape(event: String)
}

/// Pure data transformation for merging/removing CodeCat's hook entries into the
/// Claude Code `settings.json` document. Operates entirely on `Data` in and `Data`
/// out — it never touches the filesystem, so callers are free to unit test it
/// without risking the user's real settings file.
public enum HooksInstaller {
    /// The hook events CodeCat subscribes to.
    public static let events = ["SessionStart", "Stop", "Notification", "SessionEnd"]

    /// Returns a new settings document with a CodeCat hook entry (`hookCommand`)
    /// merged into every event in `events`, preserving all unrelated keys, events,
    /// and foreign hook entries already present in `json`. Idempotent: calling
    /// this twice with the same `hookCommand` does not duplicate the entry.
    public static func install(into json: Data?, hookCommand: String) throws -> Data {
        var root = try parse(json)
        var hooks: [String: Any]
        if let existingHooks = root["hooks"] {
            guard let asDict = existingHooks as? [String: Any] else {
                throw HooksInstallerError.unexpectedHooksShape(event: "hooks")
            }
            hooks = asDict
        } else {
            hooks = [:]
        }
        for event in events {
            var elements: [Any]
            if let existing = hooks[event] {
                guard let asArray = existing as? [Any] else {
                    throw HooksInstallerError.unexpectedHooksShape(event: event)
                }
                elements = asArray
            } else {
                elements = []
            }
            let dictGroups = elements.compactMap { $0 as? [String: Any] }
            if !contains(groups: dictGroups, command: hookCommand) {
                elements.append(["hooks": [["type": "command", "command": hookCommand]]])
            }
            hooks[event] = elements
        }
        root["hooks"] = hooks
        return try serialize(root)
    }

    /// Returns a new settings document with any hook entry whose command equals
    /// `hookCommand` removed. Foreign entries are left untouched; hook groups
    /// that still hold other entries keep their other keys (e.g. `matcher`)
    /// intact; groups and events that become empty as a result are deleted.
    public static func remove(from json: Data?, hookCommand: String) throws -> Data {
        var root = try parse(json)
        guard var hooks = root["hooks"] as? [String: Any] else {
            return try serialize(root)
        }
        for (event, value) in hooks {
            guard let elements = value as? [Any] else { continue }
            let filtered: [Any] = elements.compactMap { element in
                guard let group = element as? [String: Any] else {
                    return element // preserve non-dictionary elements verbatim
                }
                var g = group
                var inner = g["hooks"] as? [[String: Any]] ?? []
                inner.removeAll { ($0["command"] as? String) == hookCommand }
                guard !inner.isEmpty else { return nil } // group held only our hook
                g["hooks"] = inner
                return g
            }
            if filtered.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = filtered
            }
        }
        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }
        return try serialize(root)
    }

    /// True only when every event in `events` has a hook group containing
    /// `hookCommand` — i.e. the install is complete, not merely partial.
    public static func isInstalled(in json: Data?, hookCommand: String) -> Bool {
        guard let root = try? parse(json),
              let hooks = root["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { event in
            contains(groups: hooks[event] as? [[String: Any]] ?? [], command: hookCommand)
        }
    }

    private static func contains(groups: [[String: Any]], command: String) -> Bool {
        groups.contains { group in
            (group["hooks"] as? [[String: Any]] ?? [])
                .contains { ($0["command"] as? String) == command }
        }
    }

    /// Parses `json` into a dictionary. `nil` or empty data is treated as an
    /// empty document (`{}`) so installing into a missing settings file works.
    /// Any non-empty data that fails to parse as a JSON object throws, so a
    /// corrupt settings file is never silently replaced with `{}`.
    private static func parse(_ json: Data?) throws -> [String: Any] {
        guard let json, !json.isEmpty else { return [:] }
        guard let obj = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else {
            throw HooksInstallerError.invalidJSON
        }
        return obj
    }

    private static func serialize(_ root: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }
}
