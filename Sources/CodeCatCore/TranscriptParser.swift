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
            description = L10n.t("activity.working", "working on the task")
        } else if endsTurn {
            description = L10n.t("activity.done", "done")
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
        else { return L10n.t("activity.thinking", "thinking") }

        let input = tool["input"] as? [String: Any] ?? [:]
        let file = (input["file_path"] as? String).map { ($0 as NSString).lastPathComponent }

        switch name {
        case "Edit", "Write", "MultiEdit", "NotebookEdit":
            return file.map { L10n.f("activity.editing.file", "editing %@", $0) }
                ?? L10n.t("activity.editing", "editing files")
        case "Bash":
            return L10n.t("activity.running", "running a command")
        case "Read":
            return file.map { L10n.f("activity.reading.file", "reading %@", $0) }
                ?? L10n.t("activity.reading", "reading files")
        case "Grep", "Glob":
            return L10n.t("activity.searching", "searching the code")
        case "Task", "Agent":
            return L10n.t("activity.subagent.started", "started a subagent")
        default:
            return L10n.f("activity.tool", "using %@", name)
        }
    }
}
