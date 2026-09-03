import Foundation
import Darwin

/// Answers two questions about Claude Code's processes: how many are running right
/// now, and whether a particular one is alive.
///
/// The count used to come from `pgrep -x claude`, and that was wrong: on a live
/// machine with two sessions working at once (pids 38096 and 62846, both
/// `.../claude.app/Contents/MacOS/claude`, both named `claude` in `ps -o ucomm`
/// output), `pgrep -x claude` consistently returned **one** pid. And that was the
/// only "is the session alive" signal there was: undercounting to zero would send
/// live sessions to `.crashed` after two minutes of silence, overcounting would keep
/// a ghost working agent for hours. So the process list is taken straight from the
/// kernel (`sysctl(KERN_PROC_ALL)`), with no intermediary.
public enum ProcessScanner {
    /// How many of `names` are exactly `name`. Separated from the syscall so the
    /// counting rule can be tested without spawning processes.
    public static func count(of name: String, in names: [String]) -> Int {
        names.filter { $0 == name }.count
    }

    /// Names of every process on the system, as the kernel knows them (`p_comm`).
    ///
    /// `p_comm` is a name, not a path: it is truncated to 16 characters (`claude`
    /// fits) and, for a binary launched through a symlink, shows the symlink target's
    /// name. For counting that is the right trade: one `sysctl` call instead of
    /// `proc_pidpath` on each of hundreds of processes, and no privileges we might not
    /// have. Where accuracy about a specific process matters, the path is asked for —
    /// see `isProcess(_:named:)`.
    static func runningProcessNames() -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        // The process list can grow between measuring the size and reading; take some
        // slack and trust the size the second call returns, not the first.
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

    /// Whether process `pid` is alive and still the one we take it for.
    ///
    /// It checks not only that the pid exists but the executable's name too: pid
    /// numbers are reused, and a few hours later a recorded number may be answered by
    /// someone else's process. The full path is asked for (`proc_pidpath` inside
    /// `LiveProcessTree`) rather than `p_comm` — where a specific session's fate is
    /// being decided, a truncated name will not do.
    public static func isProcess(_ pid: pid_t, named name: String = "claude",
                                 provider: ProcessTreeProviding = LiveProcessTree()) -> Bool {
        guard pid > 0, let snapshot = provider.snapshot(for: pid),
              let path = snapshot.executablePath else { return false }
        return (path as NSString).lastPathComponent == name
    }
}
