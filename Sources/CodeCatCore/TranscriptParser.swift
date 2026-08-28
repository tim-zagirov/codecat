import Foundation

public enum TranscriptParser {
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func parseLine(_ line: String) -> TranscriptActivity? {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = obj["type"] as? String,
              type == "assistant" || type == "user",
              let sessionId = obj["sessionId"] as? String,
              let tsString = obj["timestamp"] as? String,
              let ts = isoFrac.date(from: tsString) ?? iso.date(from: tsString)
        else { return nil }

        let cwd = obj["cwd"] as? String ?? ""
        let description: String
        if type == "user" {
            description = "работает над задачей"
        } else {
            description = describeAssistant(obj)
        }
        return TranscriptActivity(sessionId: sessionId, projectPath: cwd,
                                  description: description, timestamp: ts)
    }

    private static func describeAssistant(_ obj: [String: Any]) -> String {
        let content = ((obj["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
        guard let tool = content.last(where: { $0["type"] as? String == "tool_use" }),
              let name = tool["name"] as? String
        else { return "думает" }

        let input = tool["input"] as? [String: Any] ?? [:]
        let file = (input["file_path"] as? String).map { ($0 as NSString).lastPathComponent }

        switch name {
        case "Edit", "Write", "MultiEdit", "NotebookEdit":
            return file.map { "редактирует \($0)" } ?? "редактирует файлы"
        case "Bash":
            return "выполняет команду"
        case "Read":
            return file.map { "читает \($0)" } ?? "читает файлы"
        case "Grep", "Glob":
            return "ищет по коду"
        case "Task", "Agent":
            return "запустил субагента"
        default:
            return "использует \(name)"
        }
    }
}
