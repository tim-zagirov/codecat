import Foundation

/// The pure part of logging: formatting a line, deciding about rotation, and taking
/// a tail. Kept apart from the file operations so it can be tested without touching
/// the disk.
public enum DiagnosticFormat {
    /// The file's rotation limit, and the hook's safety stop — see `DiagnosticLog`.
    public static let rotateLimit = 1 << 20      // 1 MB
    public static let hookHardLimit = 8 << 20    // 8 MB

    /// `2026-09-01 12:34:56.789 [app] text`
    ///
    /// The source is not optional: two different processes write to this file, and
    /// without the tag there is no telling "the hook fired" from "the app received the
    /// event" — which is the very distinction the hook writes here for.
    public static func line(date: Date, source: String, message: String,
                            timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        let ms = (c.nanosecond ?? 0) / 1_000_000
        // Formatted by hand rather than with DateFormatter: that is several times more
        // expensive and a line is written for every hook event. DateFormatter also
        // follows the user's locale, and in an Arabic or Thai locale the log would
        // become unreadable.
        let stamp = String(
            format: "%04d-%02d-%02d %02d:%02d:%02d.%03d",
            c.year ?? 0, c.month ?? 0, c.day ?? 0,
            c.hour ?? 0, c.minute ?? 0, c.second ?? 0, ms)
        // A newline inside the message would split one record across several lines and
        // throw the log's tail off. Escaped rather than cut: macOS error text is
        // sometimes multi-line, and losing its tail is not acceptable.
        let flat = message
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\(stamp) [\(source)] \(flat)\n"
    }

    public static func shouldRotate(size: Int, limit: Int = rotateLimit) -> Bool {
        size >= limit
    }

    /// The last `lines` lines. For a diagnostic report: the start of a log is always
    /// less interesting than what was happening just before the failure.
    public static func tail(_ text: String, lines: Int) -> String {
        guard lines > 0 else { return "" }
        // `omittingEmptySubsequences: false` matters: without it, blank lines in the
        // middle of the log would be swallowed and the tail would reach further back
        // than asked.
        var parts = text.split(separator: "\n", omittingEmptySubsequences: false)
        // The file ends with a newline, so the last element is an empty tail rather
        // than a log line; counting it as a line would return one real line fewer than
        // requested.
        if parts.last?.isEmpty == true { parts.removeLast() }
        return parts.suffix(lines).joined(separator: "\n")
    }

    /// Replaces the home directory with `~`. Applied ONLY when the log leaves the
    /// machine; full paths are written into the file itself — it sits on the user's
    /// own disk, and abbreviating it for their own benefit helps nobody.
    public static func redact(_ text: String, home: String) -> String {
        guard !home.isEmpty else { return text }
        let trimmed = home.hasSuffix("/") ? String(home.dropLast()) : home
        return text.replacingOccurrences(of: trimmed, with: "~")
    }
}

/// Appends lines to the log file. The file is shared by two processes — the app and
/// `codecat-hook` — so a line is written with a single `write(2)` to a descriptor
/// opened `O_APPEND`: the kernel guarantees such a write will not interleave with
/// anyone else's.
///
/// Rotation is done by the app ONLY. The hook lives for milliseconds and, by
/// renaming the file, would pull it out from under the app's already-open
/// descriptor — after which the app would silently write into `.1` until the next
/// rotation overwrote it. Instead the hook has a hard limit: if the app was
/// uninstalled long ago and the hooks stayed in the settings, the file stops growing
/// rather than filling the disk.
public final class DiagnosticLog {
    private let url: URL
    private let source: String
    private let lock = NSLock()
    private var fd: Int32 = -1

    public init(url: URL, source: String) {
        self.url = url
        self.source = source
    }

    /// `nil` if the file could not be opened. Logging has no right to be the cause of
    /// a failure in what it logs, so every error here is silent.
    private func handle() -> Int32? {
        if fd >= 0 { return fd }
        let opened = url.path.withCString {
            open($0, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        }
        guard opened >= 0 else { return nil }
        fd = opened
        return fd
    }

    public func write(_ message: String, at date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        guard let fd = handle() else { return }
        let text = DiagnosticFormat.line(date: date, source: source, message: message)
        guard let data = text.data(using: .utf8) else { return }
        _ = data.withUnsafeBytes { raw in
            Darwin.write(fd, raw.baseAddress, raw.count)
        }
    }

    /// The hook's safety stop: do not write into a file that has already grown, since
    /// there is nobody to rotate it. Returns `true` if writing is allowed.
    public func writeIfWithinHardLimit(_ message: String, at date: Date = Date()) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
            .flatMap { $0 } ?? 0
        guard size < DiagnosticFormat.hookHardLimit else { return false }
        write(message, at: date)
        return true
    }

    /// Renames the file to `<name>.1` once it outgrows the limit. Called by the app
    /// only, from its periodic maintenance.
    public func rotateIfNeeded(limit: Int = DiagnosticFormat.rotateLimit) {
        lock.lock()
        defer { lock.unlock() }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
            .flatMap { $0 } ?? 0
        guard DiagnosticFormat.shouldRotate(size: size, limit: limit) else { return }
        let rotated = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: url, to: rotated)
        // The descriptor points at the renamed file, not the new one — close it and
        // let the next write reopen. Without this the app would keep writing into `.1`
        // until it was restarted.
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }

    /// The log's tail. Reads the previous file as well as the current one when the
    /// current is shorter than requested: right after a rotation it holds almost
    /// nothing, and what is interesting is precisely what came before.
    public func tail(lines: Int) -> String {
        let current = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let currentTail = DiagnosticFormat.tail(current, lines: lines)
        let have = currentTail.isEmpty ? 0 : currentTail.components(separatedBy: "\n").count
        guard have < lines else { return currentTail }
        let previous = (try? String(
            contentsOf: url.appendingPathExtension("1"), encoding: .utf8)) ?? ""
        let previousTail = DiagnosticFormat.tail(previous, lines: lines - have)
        if previousTail.isEmpty { return currentTail }
        if currentTail.isEmpty { return previousTail }
        return previousTail + "\n" + currentTail
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }

    deinit { if fd >= 0 { Darwin.close(fd) } }
}
