import Foundation

public enum ProcessScanner {
    public static func count(fromPgrepOutput output: String) -> Int {
        output.split(separator: "\n").filter { !$0.isEmpty }.count
    }

    /// Internal helper that runs a process and returns its stdout as a String.
    /// Reads stdout before waiting for exit to avoid deadlock with large output.
    static func runCommand(executablePath: String, arguments: [String]) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executablePath)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            // Read stdout BEFORE waiting for exit to avoid deadlock if output > pipe buffer (64 KB)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    public static func claudeProcessCount() -> Int {
        let output = runCommand(executablePath: "/usr/bin/pgrep", arguments: ["-x", "claude"])
        return count(fromPgrepOutput: output)
    }
}
