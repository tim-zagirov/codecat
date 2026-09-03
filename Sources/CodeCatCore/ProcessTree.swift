import Foundation
import Darwin

/// One process, reduced to what routing needs. Kept separate from the syscalls that
/// produce it so ancestry logic can be tested on a modelled tree.
public struct ProcessSnapshot: Equatable, Sendable {
    public let pid: pid_t
    public let ppid: pid_t
    public let executablePath: String?
    public let tty: String?

    public init(pid: pid_t, ppid: pid_t, executablePath: String?, tty: String?) {
        self.pid = pid
        self.ppid = ppid
        self.executablePath = executablePath
        self.tty = tty
    }
}

public protocol ProcessTreeProviding {
    func snapshot(for pid: pid_t) -> ProcessSnapshot?
}

/// The application a session belongs to: the window-owning app the user can be sent to.
public struct HostApplication: Equatable, Sendable {
    public let pid: pid_t
    public let bundlePath: String

    public init(pid: pid_t, bundlePath: String) {
        self.pid = pid
        self.bundlePath = bundlePath
    }
}

public enum ProcessTree {

    /// The outermost `.app` bundle containing `path`, or nil if it is not inside one.
    ///
    /// Outermost, not innermost: an executable at
    /// `/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper`
    /// belongs to `/Applications/Claude.app` — activating the nested helper bundle
    /// shows the user nothing.
    public static func outermostBundlePath(forExecutablePath path: String) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        var prefix: [Substring] = []
        for component in components {
            prefix.append(component)
            if component.hasSuffix(".app") {
                return prefix.joined(separator: "/")
            }
        }
        return nil
    }

    /// Walks up from `pid` and returns the *last* ancestor that lives inside an
    /// `.app` bundle — the outermost application in the chain, which is the one
    /// that owns a window and answers to `activate()`. See the plan's notes: the
    /// first such ancestor is routinely a nested helper or the CLI's own bundle.
    ///
    /// `maxDepth` and the visited set are hook-safety guards: this runs inside
    /// `codecat-hook`, which Claude Code waits on, so a corrupt or cyclic parent
    /// chain must terminate rather than spin.
    ///
    /// `excludingBundlePath` is how the hook keeps itself out of the answer: the
    /// installed hook lives at `/Applications/CodeCat.app/Contents/MacOS/codecat-hook`,
    /// so its own executable resolves to a bundle. Recording CodeCat as the host of
    /// somebody else's session points the jump at a process that exits microseconds
    /// later — and at a pid that is then free to be recycled.
    public static func host(startingAt pid: pid_t,
                            provider: ProcessTreeProviding,
                            maxDepth: Int = 24,
                            excludingBundlePath: String? = nil) -> HostApplication? {
        var found: HostApplication?
        var visited: Set<pid_t> = []
        var current = pid
        for _ in 0..<maxDepth {
            guard !visited.contains(current), let snapshot = provider.snapshot(for: current) else { break }
            visited.insert(current)
            if let path = snapshot.executablePath,
               let bundle = outermostBundlePath(forExecutablePath: path),
               bundle != excludingBundlePath {
                found = HostApplication(pid: snapshot.pid, bundlePath: bundle)
            }
            guard snapshot.ppid > 1 else { break }
            current = snapshot.ppid
        }
        return found
    }

    /// PID of the nearest ancestor whose executable is named `executableName`
    /// (`claude` by default) — the process of the very session the hook was launched
    /// inside.
    ///
    /// The nearest, not the outermost, unlike `host`: when one `claude` launches
    /// another, the hook's session belongs to the inner one. The hook's ancestor chain
    /// is usually `codecat-hook` ← `sh -c` ← `claude`.
    ///
    /// The path's last component is compared rather than the kernel's process name
    /// (`p_comm`): that is truncated to 16 characters and, for a binary launched
    /// through a symlink, shows the symlink target's name rather than what the process
    /// calls itself.
    ///
    /// The same safeguards as `host`: a depth limit and a set of visited pids — this
    /// code runs inside `codecat-hook`, which Claude Code is waiting on, so a corrupt
    /// or looping ancestor chain has to terminate rather than spin.
    public static func agent(startingAt pid: pid_t,
                             provider: ProcessTreeProviding,
                             maxDepth: Int = 24,
                             executableName: String = "claude") -> pid_t? {
        var visited: Set<pid_t> = []
        var current = pid
        for _ in 0..<maxDepth {
            guard !visited.contains(current), let snapshot = provider.snapshot(for: current) else { return nil }
            visited.insert(current)
            if let path = snapshot.executablePath,
               (path as NSString).lastPathComponent == executableName {
                return snapshot.pid
            }
            guard snapshot.ppid > 1 else { return nil }
            current = snapshot.ppid
        }
        return nil
    }

    /// The controlling terminal of the session, taken from the first ancestor that
    /// has one: a wrapper process may have no tty while the shell above it does.
    public static func tty(startingAt pid: pid_t,
                           provider: ProcessTreeProviding,
                           maxDepth: Int = 24) -> String? {
        var visited: Set<pid_t> = []
        var current = pid
        for _ in 0..<maxDepth {
            guard !visited.contains(current), let snapshot = provider.snapshot(for: current) else { return nil }
            visited.insert(current)
            if let tty = snapshot.tty, !tty.isEmpty { return tty }
            guard snapshot.ppid > 1 else { return nil }
            current = snapshot.ppid
        }
        return nil
    }
}

/// `ProcessTreeProviding` backed by `sysctl(KERN_PROC_PID)` plus `proc_pidpath`.
///
/// A few syscalls and no subprocesses: this runs inside `codecat-hook`, which
/// Claude Code blocks on, so shelling out to `ps` would be paying milliseconds of
/// process spawn on every hook event.
public struct LiveProcessTree: ProcessTreeProviding {
    public init() {}

    public func snapshot(for pid: pid_t) -> ProcessSnapshot? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let rc = sysctl(&mib, 4, &kp, &size, nil, 0)
        // A dead pid returns 0 with size 0 rather than an error.
        guard rc == 0, size > 0, kp.kp_proc.p_pid == pid else { return nil }
        return ProcessSnapshot(pid: pid,
                               ppid: kp.kp_eproc.e_ppid,
                               executablePath: Self.executablePath(for: pid),
                               tty: Self.ttyName(kp.kp_eproc.e_tdev))
    }

    private static func executablePath(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// `e_tdev` is the controlling terminal's device number, or `NODEV` (-1) when
    /// the process has none — a GUI-launched session.
    private static func ttyName(_ device: dev_t) -> String? {
        // NODEV is -1; skip invalid devices
        guard device != -1, device != 0 else { return nil }
        guard let name = devname(device, S_IFCHR) else { return nil }
        return "/dev/" + String(cString: name)
    }
}
