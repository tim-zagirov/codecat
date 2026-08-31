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
        // Конец турна: модель вернула управление человеку. См. `TranscriptActivity.endsTurn`.
        // Только у ассистента: у записей пользователя (включая результаты инструментов)
        // такого поля нет и быть не может.
        let endsTurn = type == "assistant"
            && (obj["message"] as? [String: Any])?["stop_reason"] as? String == "end_turn"
        let description: String
        if type == "user" {
            description = "работает над задачей"
        } else if endsTurn {
            description = "закончил"
        } else {
            description = describeAssistant(obj)
        }
        // Субагент распознаётся по наличию непустого поля `agentId` в самой записи, а не
        // по тому, что файл лежит в подпапке `subagents/`: путь — это деталь того, как
        // Claude Code раскладывает файлы сегодня, а `agentId` — факт о самой записи,
        // который переживёт возможные будущие изменения раскладки.
        let isSubagent = !((obj["agentId"] as? String ?? "").isEmpty)
        return TranscriptActivity(sessionId: sessionId, projectPath: cwd,
                                  description: description, timestamp: ts,
                                  isSubagent: isSubagent, endsTurn: endsTurn)
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
