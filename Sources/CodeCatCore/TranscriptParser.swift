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
        // End of turn: the model handed control back to the human. See
        // `TranscriptActivity.endsTurn`. Only on the assistant's entries: user entries
        // (including tool results) have no such field and never could.
        let endsTurn = type == "assistant"
            && (obj["message"] as? [String: Any])?["stop_reason"] as? String == "end_turn"
        let description: String
        if type == "user" {
            description = L10n.t("activity.working", "working on the task")
        } else if endsTurn {
            description = L10n.t("activity.done", "finished the task")
        } else {
            description = describeAssistant(obj)
        }
        // A subagent is recognised by a non-empty `agentId` field on the entry itself,
        // not by the file sitting in a `subagents/` subdirectory: the path is a detail
        // of how Claude Code arranges files today, while `agentId` is a fact about the
        // entry that will survive any future change to that arrangement.
        let isSubagent = !((obj["agentId"] as? String ?? "").isEmpty)
        // Neither a subagent's list nor a sidechain's is the session's plan: each is
        // the errand a subordinate was sent on, under the parent's session id.
        let isSidechain = obj["isSidechain"] as? Bool == true
        let stepsUpdates = (isSubagent || isSidechain) ? [] : stepsUpdates(obj)
        // A subagent's or sidechain's own "end_turn" ends the ERRAND it was sent on,
        // not the session's turn — `finalText` becomes the row's handoff summary, and
        // a sidechain's text is not that.
        let finalText = (endsTurn && !isSidechain) ? assistantText(obj) : nil
        let pendingAction = (isSubagent || isSidechain)
            ? nil : pendingActionChange(obj, type: type, endsTurn: endsTurn)
        return TranscriptActivity(sessionId: sessionId, projectPath: cwd,
                                  description: description, timestamp: ts,
                                  isSubagent: isSubagent, endsTurn: endsTurn,
                                  taskText: taskText(obj, type: type),
                                  stepsUpdates: stepsUpdates, finalText: finalText,
                                  pendingAction: pendingAction)
    }

    /// What the user asked for, when this entry is the asking. Only a typed prompt
    /// qualifies, and the shape of one was read off live transcripts rather than
    /// guessed:
    ///
    ///  * `type == "user"` with `message.content` a plain STRING. A tool result is a
    ///    `user` entry too, but its content is an array — the agent talking to itself.
    ///  * not `isMeta`: that marks text Claude Code injected into the conversation
    ///    (caveats, image placeholders), not text a person typed.
    ///  * not `isSidechain`: a subagent's instructions travel under the PARENT
    ///    session's id, so without this the parent's row would describe the errand
    ///    the subagent was sent on.
    ///  * `origin.kind`, when present, is "human". The other kinds seen in the wild
    ///    ("task-notification") are the harness talking. A transcript without the
    ///    field at all is old, not suspicious, and still counts — `TaskText.sanitized`
    ///    throws out the machine-written shapes it cannot rule out here.
    private static func taskText(_ obj: [String: Any], type: String) -> String? {
        guard type == "user",
              let content = (obj["message"] as? [String: Any])?["content"] as? String,
              obj["isMeta"] as? Bool != true,
              obj["isSidechain"] as? Bool != true
        else { return nil }
        if let kind = (obj["origin"] as? [String: Any])?["kind"] as? String, kind != "human" {
            return nil
        }
        return TaskText.sanitized(content)
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

    /// The pending tool call: set by the assistant's last `tool_use`, cleared by any
    /// `tool_result` (the call ran) and by the end of the turn. A typed prompt says
    /// nothing either way.
    private static func pendingActionChange(_ obj: [String: Any], type: String,
                                            endsTurn: Bool) -> PendingActionChange? {
        let content = blocks(obj)
        if type == "assistant" {
            if endsTurn { return .clear }
            guard let tool = content.last(where: { $0["type"] as? String == "tool_use" }),
                  let name = tool["name"] as? String else { return nil }
            return .set(PendingAction.from(tool: name, input: tool["input"] as? [String: Any] ?? [:]))
        }
        return content.contains(where: { $0["type"] as? String == "tool_result" }) ? .clear : nil
    }

    /// The message's content blocks, or none.
    private static func blocks(_ obj: [String: Any]) -> [[String: Any]] {
        ((obj["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
    }

    /// The text of the assistant's message — every `text` block, in order, one per
    /// line. Tool blocks are skipped: they are not what the user reads.
    private static func assistantText(_ obj: [String: Any]) -> String? {
        let parts = blocks(obj).compactMap { block -> String? in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }
        let text = parts.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    /// Changes to the task list on this line. Three tools write it, read off live
    /// transcripts:
    ///  * `TodoWrite` — the whole list every time, in `input.todos`.
    ///  * `TaskUpdate` — one task's status, in `input.taskId` / `input.status`.
    ///  * `TaskCreate` — the request carries no id; the id is in the RESULT, a `user`
    ///    entry whose `tool_result` says "Task #3 created successfully: <subject>".
    ///    Reading the result needs no correlation with the request, and a create
    ///    whose result never came created nothing.
    private static func stepsUpdates(_ obj: [String: Any]) -> [StepsUpdate] {
        var updates: [StepsUpdate] = []
        for block in blocks(obj) {
            switch block["type"] as? String {
            case "tool_use":
                let input = block["input"] as? [String: Any] ?? [:]
                switch block["name"] as? String {
                case "TodoWrite":
                    let todos = input["todos"] as? [[String: Any]] ?? []
                    let steps = todos.enumerated().compactMap { index, todo -> TaskStep? in
                        guard let raw = todo["content"] as? String,
                              let title = TaskText.sanitized(raw),
                              let status = stepStatus(todo["status"] as? String) else { return nil }
                        let active = (todo["activeForm"] as? String).flatMap(TaskText.sanitized)
                        return TaskStep(id: String(index), title: title, activeForm: active, status: status)
                    }
                    updates.append(.replaceAll(steps))
                case "TaskUpdate":
                    // The id is a string in every payload seen; a number is accepted
                    // in case a future build sends one.
                    let id = (input["taskId"] as? String) ?? (input["taskId"] as? Int).map(String.init)
                    guard let id else { break }
                    let raw = input["status"] as? String
                    if raw == "deleted" {
                        updates.append(.remove(id: id))
                    } else if let status = stepStatus(raw) {
                        updates.append(.update(id: id, status: status))
                    }
                default:
                    break
                }
            case "tool_result":
                // The result is a plain string or an array of text blocks — both
                // shapes occur in the same transcript.
                let texts: [String]
                if let text = block["content"] as? String {
                    texts = [text]
                } else {
                    texts = (block["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
                }
                for text in texts {
                    if let created = taskCreated(text) { updates.append(created) }
                }
            default:
                break
            }
        }
        return updates
    }

    private static func stepStatus(_ raw: String?) -> TaskStep.Status? {
        switch raw {
        case "pending": return .pending
        case "in_progress": return .inProgress
        case "completed": return .completed
        default: return nil
        }
    }

    private static let taskCreatedPattern = try! NSRegularExpression(
        pattern: #"^Task #(\d+) created successfully: (.+)$"#, options: [.anchorsMatchLines])

    private static func taskCreated(_ text: String) -> StepsUpdate? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = taskCreatedPattern.firstMatch(in: text, range: range),
              let idRange = Range(match.range(at: 1), in: text),
              let titleRange = Range(match.range(at: 2), in: text),
              let title = TaskText.sanitized(String(text[titleRange])) else { return nil }
        return .create(id: String(text[idRange]), title: title)
    }
}
