import Foundation

public enum CodeCatPaths {
    public static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    public static var appSupport: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodeCat", isDirectory: true)
    }

    public static var socketURL: URL {
        appSupport.appendingPathComponent("codecat.sock")
    }

    /// Persisted `SessionRoute` map — see `SessionRouteCache`. Lives next to the
    /// socket in Application Support, per the design spec.
    public static var routeCacheURL: URL {
        appSupport.appendingPathComponent("routes.json")
    }

    /// The log file — next to the socket and the route cache. Two processes write to
    /// it: the app and `codecat-hook` (see `DiagnosticLog`). The app is `LSUIElement`
    /// with no window and no console, and this is the only way to learn what happened
    /// inside it.
    public static var logURL: URL {
        appSupport.appendingPathComponent("codecat.log")
    }

    public static var claudeSettings: URL {
        home.appendingPathComponent(".claude/settings.json")
    }

    public static var projectsRoot: URL {
        home.appendingPathComponent(".claude/projects", isDirectory: true)
    }

    public static func ensureAppSupportExists() {
        try? FileManager.default.createDirectory(
            at: appSupport, withIntermediateDirectories: true)
    }
}
