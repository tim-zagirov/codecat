import Foundation
import CoreServices

/// Следит за ~/.claude/projects/**/*.jsonl через FSEvents,
/// новые строки прогоняет через TranscriptParser и отдаёт наружу.
public final class TranscriptWatcher {
    private let root: URL
    private let onActivity: (TranscriptActivity) -> Void
    private let tailer = FileTailer()
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "codecat.transcript-watcher")

    public init(root: URL, onActivity: @escaping (TranscriptActivity) -> Void) {
        self.root = root
        self.onActivity = onActivity
    }

    public func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<TranscriptWatcher>.fromOpaque(info).takeUnretainedValue()
            let cfPaths = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            for path in cfPaths.prefix(count) {
                watcher.handleChange(atPath: path)
            }
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
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
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
