import Foundation
import CoreServices

/// Следит за ~/.claude/projects/**/*.jsonl через FSEvents,
/// новые строки прогоняет через TranscriptParser и отдаёт наружу.
///
/// FSEvents — доставка «по возможности», а не гарантия, и это заметно ровно тогда,
/// когда человек работает над несколькими проектами сразу: файлов, меняющихся
/// одновременно, много. Поэтому у наблюдателя две независимые опоры:
///
/// - **Push.** События FSEvents. Их флаги обязаны разбираться: при переполнении
///   очереди ядро выдаёт не путь к файлу, а `MustScanSubDirs`/`KernelDropped`/
///   `UserDropped` с путём к *каталогу* — раньше такой путь молча отсеивался
///   проверкой «оканчивается на .jsonl», и вместе с ним терялась вся пачка
///   изменений, а котик застревал в позе, которая уже неправда.
/// - **Poll.** Медленный обход недавно изменённых файлов раз в `pollInterval`.
///   Страховка на классы отказов, о которых push не сообщает вовсе: поток
///   FSEvents перестал приходить, корневой каталог пересоздали
///   (`kFSEventStreamEventFlagRootChanged`), система была занята. Стоит она
///   недорого — один обход дерева и `stat` на файл, — а верхнюю границу
///   отставания состояния делает предсказуемой: `pollInterval`, что бы ни
///   случилось с push.
///
/// Обе опоры ведут в один и тот же `FileTailer`, помнящий смещение по каждому
/// файлу, поэтому повторный проход по файлу, о котором уже пришло событие, ничего
/// не дублирует: новых строк там просто нет.
public final class TranscriptWatcher {
    private let root: URL
    private let onActivity: (TranscriptActivity) -> Void
    private let tailer = FileTailer()
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "codecat.transcript-watcher")

    /// Как часто проходить по дереву в качестве страховки.
    private let pollInterval: TimeInterval
    /// Насколько свежим должен быть файл, чтобы его смотрел обход. Заметно больше
    /// `pollInterval`: окно должно с запасом перекрывать паузу между обходами,
    /// иначе файл, изменившийся сразу после обхода, успел бы «остыть» к следующему.
    private let rescanWindow: TimeInterval
    private var pollTimer: DispatchSourceTimer?

    /// Сколько раз пришлось обходить дерево целиком — из-за потерянных событий или
    /// по таймеру страховки. Нужен тестам и диагностике: по нему видно, работает ли
    /// push вообще. Под замком — пишется на `queue`, а читают снаружи.
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
        // FSEvents держит непроверяемый (Unmanaged.passUnretained) указатель
        // на self в контексте потока; без остановки здесь коллбэк может
        // сработать после освобождения self и разыменовать чужую память.
        stop()
    }

    public func start() {
        // ПЕРВЫМ делом — восстановить картину уже идущей работы. Обязано стоять до
        // FileTailer'а: тот при первой встрече с файлом ставит смещение в конец и
        // истории не отдаёт, поэтому после него хвосты читать уже поздно.
        primeFromExistingTranscripts()
        // Обход-страховка заводится первым и независимо от FSEvents: если поток
        // событий не создался вовсе, наблюдатель обязан продолжать работать —
        // медленнее, но работать, а не молчать.
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
                // Не `Self.` — из замыкания, которое становится сишным указателем на
                // функцию, нельзя ссылаться на динамический Self.
                if TranscriptWatcher.meansLostEvents(flags[index]) { lost = true; continue }
                watcher.handleChange(atPath: cfPaths[index])
            }
            // Обход — после разбора остальных путей: то, что доехало, обрабатывается
            // в любом случае, даже если часть пачки потерялась.
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

    /// Флаги, означающие «часть событий до тебя не доехала». `RootChanged` тоже
    /// здесь: корень пересоздали, и всё, что мы про него помним, пора перепроверить.
    static func meansLostEvents(_ flags: FSEventStreamEventFlags) -> Bool {
        let lossy = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagRootChanged)
        return flags & lossy != 0
    }

    /// Восстанавливает картину уже идущей работы из существующих транскриптов.
    ///
    /// Зачем. До этого при запуске приложение не узнавало о живых сессиях НИКАК —
    /// не «медленно», а никак. Складывались три вещи: поток FSEvents создаётся с
    /// `kFSEventStreamEventIdSinceNow` и о прошлом не сообщает; обход-страховка
    /// заводится с задержкой в целый `pollInterval`; а `FileTailer` при первой
    /// встрече с файлом ставит смещение в конец и историю намеренно не переигрывает.
    /// Поэтому агент, занятый долгим вызовом инструмента, в транскрипт ничего не
    /// пишет — и остаётся невидимым, пока не напишет. Замер на живой машине,
    /// восемь перезапусков подряд: 4, 7, 9, 11, 18, 25, 33 и 89 секунд слепоты.
    ///
    /// Особенно больно это с включённым «прятать котика, когда сессий нет»: маскот
    /// не просто показывает спящего кота, его вовсе нет на экране, пока агент
    /// работает.
    ///
    /// Читается хвост, а не файл целиком: транскрипт длинной сессии — это мегабайты,
    /// а нужно только текущее состояние. Первая строка куска отбрасывается, если
    /// начали не с начала файла: почти наверняка она обрезана посередине.
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

    /// Последние `bytes` байт файла, разобранные на целые строки.
    static func tailLines(of url: URL, bytes: Int) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return [] }
        var lines = text.components(separatedBy: "\n")
        // Начали с середины файла — первая строка почти наверняка обрезана.
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

    /// Проходит по недавно изменённым `.jsonl` и подтягивает их хвосты. Вызывается
    /// только на `queue` — и обработчик FSEvents, и таймер страховки живут на ней,
    /// поэтому `FileTailer` (он не потокобезопасен) всегда трогает один поток.
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
