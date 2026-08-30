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
            // того, что мы уже ЧИТАЛИ раньше. Но "читали" — это не то же
            // самое, что "отдали вызывающему": offset считает и байты,
            // осевшие в partial (хвост без "\n", который ещё ни разу не
            // вернули из newLines). Если усечение попадает СТРОГО ВНУТРЬ
            // этого ещё не отданного хвоста, часть partial'а на самом деле
            // уже отсутствует физически быть не может — она вся ещё лежит
            // в файле (просто не была отдана), и наивный сброс partial'а
            // в nil потерял бы эти байты навсегда.
            //
            // Граница уже ОТДАННЫХ байт — offset минус длина буфера partial
            // (в байтах UTF-8, т.к. offset — это счётчик байт, а не символов).
            let partialByteCount = UInt64(known.partial?.utf8.count ?? 0)
            let deliveredBoundary = known.offset - partialByteCount

            if size > deliveredBoundary {
                // Усечение пришлось строго внутри буферизованного partial:
                // сохраняем уцелевший префикс partial'а (первые
                // size - deliveredBoundary байт) вместо того, чтобы его
                // выбросить.
                let survivingByteCount = Int(size - deliveredBoundary)
                if let partial = known.partial,
                    let survivingPrefix = Self.utf8Prefix(of: partial, byteCount: survivingByteCount)
                {
                    states[key] = FileState(inode: inode, offset: size, partial: survivingPrefix)
                    return []
                }
                // Обрезка пришлась на середину многобайтового символа —
                // корректно разделить не можем. Откатываемся к полному
                // сбросу, чтобы не вернуть невалидный текст.
                states[key] = FileState(inode: inode, offset: size, partial: nil)
                return []
            }

            // Усечение не задело буферизованный partial (он был отдан
            // раньше и/или обрезка ушла ниже границы уже отданного) —
            // прежнее поведение: просто перепрыгиваем смещение на конец
            // файла и молчим.
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

    /// Возвращает первые `byteCount` байт UTF-8 представления `string` как
    /// строку, либо nil, если такая граница разрезала бы многобайтовый
    /// символ пополам (в этом случае корректный префикс-строку получить
    /// нельзя).
    private static func utf8Prefix(of string: String, byteCount: Int) -> String? {
        let bytes = Array(string.utf8)
        guard byteCount >= 0, byteCount <= bytes.count else { return nil }
        return String(bytes: bytes[0..<byteCount], encoding: .utf8)
    }
}
