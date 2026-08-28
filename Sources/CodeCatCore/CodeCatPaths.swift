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
