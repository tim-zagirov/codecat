import Foundation

/// Чистая часть логирования: форматирование строки, решение о ротации и выборка
/// хвоста. Вынесена отдельно от файловых операций, чтобы её можно было проверить
/// тестами, не трогая диск.
public enum DiagnosticFormat {
    /// Предел файла до ротации и предохранитель для хука — см. `DiagnosticLog`.
    public static let rotateLimit = 1 << 20      // 1 МБ
    public static let hookHardLimit = 8 << 20    // 8 МБ

    /// `2026-09-01 12:34:56.789 [app] текст`
    ///
    /// Источник в строке обязателен: в файл пишут два разных процесса, и без метки
    /// нельзя отличить «хук выстрелил» от «приложение получило событие» — а это
    /// ровно то различие, ради которого хук вообще сюда пишет.
    public static func line(date: Date, source: String, message: String,
                            timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        let ms = (c.nanosecond ?? 0) / 1_000_000
        // Форматируется вручную, а не DateFormatter: он в разы дороже, а строка
        // пишется на каждое событие хука. Плюс DateFormatter зависит от локали
        // пользователя, и в арабской или тайской локали лог стал бы нечитаемым.
        let stamp = String(
            format: "%04d-%02d-%02d %02d:%02d:%02d.%03d",
            c.year ?? 0, c.month ?? 0, c.day ?? 0,
            c.hour ?? 0, c.minute ?? 0, c.second ?? 0, ms)
        // Перевод строки внутри сообщения разорвал бы одну запись на несколько
        // строк, и хвост лога поехал бы. Экранируем, а не режем: текст ошибки от
        // macOS бывает многострочным, и терять его хвост нельзя.
        let flat = message
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\(stamp) [\(source)] \(flat)\n"
    }

    public static func shouldRotate(size: Int, limit: Int = rotateLimit) -> Bool {
        size >= limit
    }

    /// Последние `lines` строк. Для отчёта о диагностике: начало лога всегда менее
    /// интересно, чем то, что происходило перед сбоем.
    public static func tail(_ text: String, lines: Int) -> String {
        guard lines > 0 else { return "" }
        // `omittingEmptySubsequences: false` важен: иначе пустые строки в середине
        // лога съедались бы и хвост уезжал бы дальше, чем просили.
        var parts = text.split(separator: "\n", omittingEmptySubsequences: false)
        // Файл кончается переводом строки, поэтому последний элемент — пустой
        // хвост, а не строка лога; считать его за строку значило бы отдавать на
        // одну реальную строку меньше, чем просили.
        if parts.last?.isEmpty == true { parts.removeLast() }
        return parts.suffix(lines).joined(separator: "\n")
    }

    /// Заменяет домашний каталог на `~`. Применяется ТОЛЬКО когда лог покидает
    /// машину; в сам файл пути пишутся полностью — он лежит у пользователя, и
    /// урезать его себе же незачем.
    public static func redact(_ text: String, home: String) -> String {
        guard !home.isEmpty else { return text }
        let trimmed = home.hasSuffix("/") ? String(home.dropLast()) : home
        return text.replacingOccurrences(of: trimmed, with: "~")
    }
}

/// Дописывает строки в файл лога. Файл общий для двух процессов — приложения и
/// `codecat-hook`, — поэтому запись идёт одним `write(2)` в дескриптор, открытый с
/// `O_APPEND`: ядро гарантирует, что такая запись не перемешается с чужой.
///
/// Ротацию делает ТОЛЬКО приложение. Хук живёт миллисекунды и, переименовав файл,
/// увёл бы его из-под уже открытого дескриптора приложения — дальше приложение
/// молча писало бы в `.1`, который следующая ротация затрёт. Вместо ротации у хука
/// стоит жёсткий предел: если приложение давно снесли, а хуки в настройках
/// остались, файл перестанет расти вместо того, чтобы забить диск.
public final class DiagnosticLog {
    private let url: URL
    private let source: String
    private let lock = NSLock()
    private var fd: Int32 = -1

    public init(url: URL, source: String) {
        self.url = url
        self.source = source
    }

    /// `nil`, если файл открыть не удалось. Логирование не имеет права быть
    /// причиной сбоя того, что оно логирует, поэтому все ошибки здесь глухие.
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

    /// Предохранитель для хука: не писать в файл, который уже разросся, потому что
    /// ротировать его некому. Возвращает `true`, если писать можно.
    public func writeIfWithinHardLimit(_ message: String, at date: Date = Date()) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
            .flatMap { $0 } ?? 0
        guard size < DiagnosticFormat.hookHardLimit else { return false }
        write(message, at: date)
        return true
    }

    /// Переименовывает файл в `<имя>.1`, когда он перерос предел. Зовёт только
    /// приложение, с его периодического обслуживания.
    public func rotateIfNeeded(limit: Int = DiagnosticFormat.rotateLimit) {
        lock.lock()
        defer { lock.unlock() }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
            .flatMap { $0 } ?? 0
        guard DiagnosticFormat.shouldRotate(size: size, limit: limit) else { return }
        let rotated = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: url, to: rotated)
        // Дескриптор указывает на переименованный файл, а не на новый — закрываем,
        // следующая запись откроет заново. Без этого приложение продолжило бы
        // писать в `.1` до самого перезапуска.
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }

    /// Хвост лога. Читает и текущий файл, и предыдущий, если текущий короче
    /// запрошенного: сразу после ротации в нём почти ничего нет, а интересное —
    /// именно перед ней.
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
