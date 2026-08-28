import Foundation

/// Помнит смещение по каждому файлу и отдаёт только новые полные строки.
public final class FileTailer {
    private var offsets: [String: UInt64] = [:]
    private var partial: [String: String] = [:]

    public init() {}

    public func newLines(of url: URL) -> [String] {
        let key = url.path
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0

        guard let known = offsets[key] else {
            offsets[key] = size // первый раз видим файл — историю не переигрываем
            return []
        }
        if size < known { // файл пересоздали/усекли
            offsets[key] = size
            partial[key] = nil
            return []
        }
        guard size > known else { return [] }

        try? handle.seek(toOffset: known)
        let data = (try? handle.readToEnd()) ?? Data()
        offsets[key] = known + UInt64(data.count)

        let text = (partial[key] ?? "") + (String(data: data, encoding: .utf8) ?? "")
        var lines = text.components(separatedBy: "\n")
        partial[key] = lines.removeLast() // последний кусок без \n — в буфер
        if partial[key]?.isEmpty == true { partial[key] = nil }
        return lines.filter { !$0.isEmpty }
    }
}
