import Foundation
import Darwin

/// Отвечает на два вопроса о процессах Claude Code: сколько их сейчас в системе и
/// жив ли конкретный.
///
/// Раньше счёт брался у `pgrep -x claude`, и это было неверно: на живой машине с
/// двумя одновременно работающими сессиями (pid 38096 и 62846, оба —
/// `.../claude.app/Contents/MacOS/claude`, оба с именем `claude` в выводе
/// `ps -o ucomm`) `pgrep -x claude` устойчиво возвращал **один** pid. А это был
/// единственный сигнал «жива ли сессия»: занижение до нуля отправило бы живые
/// сессии в `.crashed` через две минуты тишины, завышение — держало бы призрак
/// работающего агента часами. Поэтому список процессов берётся напрямую у ядра
/// (`sysctl(KERN_PROC_ALL)`), без посредника.
public enum ProcessScanner {
    /// Сколько среди `names` ровно `name`. Отделено от синтаксиса, чтобы правило
    /// счёта можно было проверить, не заводя процессов.
    public static func count(of name: String, in names: [String]) -> Int {
        names.filter { $0 == name }.count
    }

    /// Имена всех процессов в системе, как их знает ядро (`p_comm`).
    ///
    /// `p_comm` — имя, а не путь: оно обрезано до 16 символов (`claude` в них
    /// укладывается) и для бинарника, запущенного через симлинк, показывает имя
    /// цели симлинка. Для счёта это правильный компромисс: одно обращение к
    /// `sysctl` вместо `proc_pidpath` на каждый из сотен процессов, и никаких
    /// прав, которых у нас может не быть. Там, где важна точность по конкретному
    /// процессу, спрашивается путь — см. `isProcess(_:named:)`.
    static func runningProcessNames() -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        // Список процессов может вырасти между замером размера и чтением; берём
        // запас и доверяем размеру, который вернул второй вызов, а не первый.
        size += MemoryLayout<kinfo_proc>.stride * 32
        let count = size / MemoryLayout<kinfo_proc>.stride
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, 4, &buffer, &size, nil, 0) == 0 else { return [] }
        let actual = size / MemoryLayout<kinfo_proc>.stride
        return buffer.prefix(actual).map { entry in
            var proc = entry.kp_proc
            return withUnsafePointer(to: &proc.p_comm) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) {
                    String(cString: $0)
                }
            }
        }
    }

    public static func claudeProcessCount() -> Int {
        count(of: "claude", in: runningProcessNames())
    }

    /// Жив ли процесс `pid` и он ли всё ещё тот, за кого мы его принимаем.
    ///
    /// Проверяется не только существование pid, но и имя исполняемого файла:
    /// номера pid переиспользуются, и через несколько часов по записанному номеру
    /// может отвечать чужой процесс. Спрашиваем полный путь (`proc_pidpath` внутри
    /// `LiveProcessTree`), а не `p_comm`, — там, где решается судьба конкретной
    /// сессии, обрезанное имя не годится.
    public static func isProcess(_ pid: pid_t, named name: String = "claude",
                                 provider: ProcessTreeProviding = LiveProcessTree()) -> Bool {
        guard pid > 0, let snapshot = provider.snapshot(for: pid),
              let path = snapshot.executablePath else { return false }
        return (path as NSString).lastPathComponent == name
    }
}
