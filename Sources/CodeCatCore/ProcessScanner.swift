import Foundation

public enum ProcessScanner {
    public static func count(fromPgrepOutput output: String) -> Int {
        output.split(separator: "\n").filter { !$0.isEmpty }.count
    }

    public static func claudeProcessCount() -> Int {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-x", "claude"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return 0
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return count(fromPgrepOutput: String(data: data, encoding: .utf8) ?? "")
    }
}
