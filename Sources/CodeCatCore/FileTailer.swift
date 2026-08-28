import Foundation

/// Помнит смещение по каждому файлу и отдаёт только новые полные строки.
public final class FileTailer {
    private struct FileState {
        var inode: UInt64
        var offset: UInt64
        var partial: String?
    }

    private var states: [String: FileState] = [:]

    public init() {}

    public func newLines(of url: URL) -> [String] {
        let key = url.path
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        // Инод читаем из уже открытого хэндла (fstat), чтобы не было
        // зазора между проверкой и чтением (TOCTOU).
        guard let inode = Self.inode(ofOpen: handle) else { return [] }
        let size = (try? handle.seekToEnd()) ?? 0

        guard let known = states[key] else {
            // первый раз видим файл — историю не переигрываем
            states[key] = FileState(inode: inode, offset: size, partial: nil)
            return []
        }

        if known.inode != inode {
            // Файл по этому пути пересоздан: удалён и создан заново, либо
            // атомарно переписан (temp file + rename, как делает
            // String.write(atomically: true)). Старое смещение относится
            // к прежнему иноду и бессмысленно для нового содержимого —
            // читаем новый файл с его собственного начала.
            return readAndAdvance(handle: handle, key: key, inode: inode, from: 0, partial: nil)
        }

        if size < known.offset {
            // Файл усечён на месте (тот же инод, но стал короче). Раз инод
            // не изменился, оставшиеся байты — это обязательно префикс
            // того, что мы уже прочитали и отдали раньше. Поэтому здесь
            // НЕЛЬЗЯ читать с байта 0 (в отличие от пересоздания файла) —
            // это заново отдало бы уже доставленные строки. Просто
            // перепрыгиваем смещение на конец файла и молчим.
            states[key] = FileState(inode: inode, offset: size, partial: nil)
            return []
        }

        guard size > known.offset else { return [] }
        return readAndAdvance(handle: handle, key: key, inode: inode, from: known.offset, partial: known.partial)
    }

    private func readAndAdvance(
        handle: FileHandle, key: String, inode: UInt64, from offset: UInt64, partial: String?
    ) -> [String] {
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        let newOffset = offset + UInt64(data.count)

        let text = (partial ?? "") + (String(data: data, encoding: .utf8) ?? "")
        var lines = text.components(separatedBy: "\n")
        var newPartial: String? = lines.removeLast() // последний кусок без \n — в буфер
        if newPartial?.isEmpty == true { newPartial = nil }

        states[key] = FileState(inode: inode, offset: newOffset, partial: newPartial)
        return lines.filter { !$0.isEmpty }
    }

    private static func inode(ofOpen handle: FileHandle) -> UInt64? {
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { return nil }
        return UInt64(info.st_ino)
    }
}
