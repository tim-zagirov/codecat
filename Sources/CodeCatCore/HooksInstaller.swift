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
/// Result of trying to read `~/.claude/settings.json` off disk, distinguishing "no file
/// yet" (safe to treat as an empty document) from "a file is there but couldn't be read"
/// (never safe to treat as empty — see `HooksInstaller.readSettings`).
public enum SettingsReadResult: Equatable {
    case notFound
    case data(Data)
    case unreadable
}

public enum HooksInstaller {
    /// The hook events CodeCat subscribes to.
    ///
    /// `UserPromptSubmit` is the exact moment an agent took on work. Without it, the
    /// start of work had to be learned from the transcript, which arrives in batches:
    /// on a live machine a 21-second delay was measured between a line being written
    /// and FSEvents reporting it. The cat slept through all of that while the agent was
    /// already working. The hook arrives over the socket immediately.
    public static let events = [
        "SessionStart", "UserPromptSubmit", "Stop", "Notification", "SessionEnd",
    ]

    /// Reads the settings file at `url`, distinguishing "does not exist" from "exists but
    /// could not be read". This distinction matters because `install(into:hookCommand:)`
    /// treats `nil`/empty input as `{}` — correct for a first-time install, but
    /// catastrophic if applied to a transient read failure on a file that actually holds
    /// the user's real settings (permission allowlist, MCP config, model settings, other
    /// hooks): the resulting write would silently replace all of it with a document
    /// containing only CodeCat's own hooks. Callers must abort instead of installing when
    /// this returns `.unreadable`.
    public static func readSettings(at url: URL) -> SettingsReadResult {
        guard FileManager.default.fileExists(atPath: url.path) else { return .notFound }
        guard let data = try? Data(contentsOf: url) else { return .unreadable }
        return .data(data)
    }

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
            var elements = try hookArray(hooks[event], event: event)
            if !containsCommand(hookCommand, in: elements) {
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
                guard let inner = group["hooks"] as? [Any] else {
                    return group // no usable "hooks" array — preserve the group unchanged
                }
                let newInner = inner.filter { !isCommandEntry($0, command: hookCommand) }
                guard !newInner.isEmpty else { return nil } // group held only our hook(s)
                var g = group
                g["hooks"] = newInner
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
            guard let elements = try? hookArray(hooks[event], event: event) else { return false }
            return containsCommand(hookCommand, in: elements)
        }
    }

    /// Reads the value stored at `hooks.<event>` as a JSON array, preserving
    /// every element regardless of its type. A missing value reads as an empty
    /// array (so a first-time install has something to append to). A present
    /// value that is not an array at all cannot safely hold hook groups, so it
    /// throws rather than being silently discarded via a `?? []` fallback.
    private static func hookArray(_ raw: Any?, event: String) throws -> [Any] {
        guard let raw else { return [] }
        guard let array = raw as? [Any] else {
            throw HooksInstallerError.unexpectedHooksShape(event: event)
        }
        return array
    }

    /// True when `element` is a dictionary (a group's inner command entry, or
    /// a bare group using the same shape) whose "command" value equals
    /// `command`. Non-dictionary elements never match — callers preserve them
    /// verbatim rather than treating a failed cast as "no match found here".
    private static func isCommandEntry(_ element: Any, command: String) -> Bool {
        (element as? [String: Any])?["command"] as? String == command
    }

    /// True if any recognizable hook group among `elements` (an event's raw
    /// hook array) carries a command entry equal to `command`. Elements that
    /// are not dictionaries, and a group's "hooks" value when it is not an
    /// array, are simply not matched — never treated as an all-or-nothing
    /// cast failure that would misjudge the whole array.
    private static func containsCommand(_ command: String, in elements: [Any]) -> Bool {
        elements.contains { element in
            guard let group = element as? [String: Any] else { return false }
            let inner = (group["hooks"] as? [Any]) ?? []
            return inner.contains { isCommandEntry($0, command: command) }
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
