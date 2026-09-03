import Foundation
import CoreServices

/// Watches ~/.claude/projects/**/*.jsonl through FSEvents, runs new lines through
/// TranscriptParser and hands them out.
///
/// FSEvents is best-effort delivery, not a guarantee, and that shows exactly when
/// someone is working on several projects at once: many files change at the same
/// time. So the watcher stands on two independent legs:
///
/// - **Push.** FSEvents events. Their flags must be examined: when the kernel's
///   queue overflows it reports not a file path but `MustScanSubDirs` /
///   `KernelDropped` / `UserDropped` with the path to a *directory* — which an
///   "ends in .jsonl" check used to discard silently, taking the whole batch of
///   changes with it and leaving the cat stuck in a pose that was no longer true.
/// - **Poll.** A slow walk over recently modified files every `pollInterval`.
///   Insurance against the classes of failure push says nothing about at all: the
///   FSEvents stream stopped arriving, the root directory was recreated
///   (`kFSEventStreamEventFlagRootChanged`), the system was busy. It is cheap — one
///   tree walk and a `stat` per file — and it makes the worst case predictable:
///   `pollInterval`, whatever happens to push.
///
/// Both legs lead into the same `FileTailer`, which remembers an offset per file,
/// so walking a file an event already reported duplicates nothing: there are simply
/// no new lines in it.
public final class TranscriptWatcher {
    private let root: URL
    private let onActivity: (TranscriptActivity) -> Void
    private let tailer = FileTailer()
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "codecat.transcript-watcher")

    /// How often to walk the tree as insurance.
    private let pollInterval: TimeInterval
    /// How recently a file must have changed for the walk to look at it. Noticeably
    /// larger than `pollInterval`: the window has to cover the gap between walks with
    /// room to spare, or a file changed just after one walk would go cold before the next.
    private let rescanWindow: TimeInterval
    private var pollTimer: DispatchSourceTimer?

    /// How many times the whole tree had to be walked — because events were lost or
    /// because the insurance timer fired. Used by tests and diagnostics: it shows
    /// whether push works at all. Behind a lock — written on `queue`, read from outside.
    public var rescanCount: Int { countLock.withLock { rescans } }
    private var rescans = 0
    private let countLock = NSLock()

    public init(root: URL,
                pollInterval: TimeInterval = 20,
                rescanWindow: TimeInterval = 10 * 60,
                onActivity: @escaping (TranscriptActivity) -> Void) {
        self.root = root
        self.pollInterval = pollInterval
        self.rescanWindow = rescanWindow
        self.onActivity = onActivity
    }

    deinit {
        // FSEvents holds an unchecked (Unmanaged.passUnretained) pointer to self in
        // the stream's context; without stopping here the callback can fire after self
        // is deallocated and dereference someone else's memory.
        stop()
    }

    public func start() {
        // FIRST of all, recover the picture of work already in progress. This must
        // come before the FileTailer: the tailer sets its offset to the end the first
        // time it meets a file and hands out no history, so after it there is no point
        // reading tails any more.
        primeFromExistingTranscripts()
        // The insurance walk is started first and independently of FSEvents: if the
        // event stream never gets created at all, the watcher must keep working —
        // slower, but working, not silent.
        if pollTimer == nil { startPolling() }
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<TranscriptWatcher>.fromOpaque(info).takeUnretainedValue()
            let cfPaths = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            var lost = false
            for index in 0..<count where index < cfPaths.count {
                // Not `Self.` — a closure that becomes a C function pointer cannot
                // refer to the dynamic Self.
                if TranscriptWatcher.meansLostEvents(flags[index]) { lost = true; continue }
                watcher.handleChange(atPath: cfPaths[index])
            }
            // The walk comes after the other paths are handled: whatever did arrive is
            // processed either way, even if part of the batch was lost.
            if lost { watcher.rescan() }
        }

        guard let s = FSEventStreamCreate(
            nil, callback, &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes))
        else { return }
        stream = s
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
    }

    public func stop() {
        pollTimer?.cancel()
        pollTimer = nil
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    /// Flags meaning "some events never reached you". `RootChanged` belongs here too:
    /// the root was recreated, and everything remembered about it needs rechecking.
    static func meansLostEvents(_ flags: FSEventStreamEventFlags) -> Bool {
        let lossy = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagRootChanged)
        return flags & lossy != 0
    }

    /// Recovers the picture of work already in progress from existing transcripts.
    ///
    /// Why. Before this, the app learned about live sessions at startup by NO means at
    /// all — not "slowly", but not at all. Three things combined: the FSEvents stream
    /// is created with `kFSEventStreamEventIdSinceNow` and reports nothing about the
    /// past; the insurance walk starts a whole `pollInterval` later; and `FileTailer`
    /// sets its offset to the end the first time it meets a file and deliberately does
    /// not replay history. So an agent busy with a long tool call writes nothing to
    /// the transcript — and stays invisible until it does. Measured on a live machine
    /// over eight consecutive restarts: 4, 7, 9, 11, 18, 25, 33 and 89 seconds of
    /// blindness.
    ///
    /// It hurts most with "hide the cat when nothing is running" on: the mascot does
    /// not merely show a sleeping cat, it is absent from the screen entirely while an
    /// agent works.
    ///
    /// The tail is read rather than the whole file: a long session's transcript runs
    /// to megabytes and only the current state is needed. The chunk's first line is
    /// dropped when reading did not start at the beginning of the file: it is almost
    /// certainly cut in half.
    func primeFromExistingTranscripts(now: Date = Date(), tailBytes: Int = 64 * 1024) {
        let cutoff = now.addingTimeInterval(-rescanWindow)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified >= cutoff
            else { continue }
            for line in Self.tailLines(of: url, bytes: tailBytes) {
                if let activity = TranscriptParser.parseLine(line) {
                    DispatchQueue.main.async { self.onActivity(activity) }
                }
            }
        }
    }

    /// The last `bytes` bytes of a file, split into whole lines.
    static func tailLines(of url: URL, bytes: Int) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return [] }
        var lines = text.components(separatedBy: "\n")
        // Started mid-file, so the first line is almost certainly truncated.
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return lines.filter { !$0.isEmpty }
    }

    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        timer.setEventHandler { [weak self] in self?.rescan() }
        pollTimer = timer
        timer.resume()
    }

    /// Walks recently modified `.jsonl` files and pulls in their tails. Called on
    /// `queue` only — both the FSEvents handler and the insurance timer live on it, so
    /// `FileTailer` (which is not thread-safe) is always touched by one thread.
    func rescan(now: Date = Date()) {
        countLock.withLock { rescans += 1 }
        let cutoff = now.addingTimeInterval(-rescanWindow)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified >= cutoff
            else { continue }
            handleChange(atPath: url.path)
        }
    }

    private func handleChange(atPath path: String) {
        guard path.hasSuffix(".jsonl") else { return }
        let url = URL(fileURLWithPath: path)
        for line in tailer.newLines(of: url) {
            if let activity = TranscriptParser.parseLine(line) {
                DispatchQueue.main.async { self.onActivity(activity) }
            }
        }
    }
}
