import Foundation

/// The one line a peek and a waiting card say about a session: *what* it wants.
/// Segments rather than a string so the view can draw commands, file names and
/// hosts as inline code without parsing its own text back.
public enum PeekReason {
    public enum Segment: Equatable, Sendable {
        case text(String)
        case code(String)
    }

    public static func segments(for session: Session) -> [Segment] {
        switch session.status {
        case .waitingForYou(.permission):
            if let action = session.pendingAction { return segments(for: action) }
            if let sentence = firstSentence(session.waitMessage) { return [.text(sentence)] }
            return [.text(session.status.title)]
        case .waitingForYou(.question):
            return [.text(L10n.t("peek.reason.question", "has a question for you"))]
        case .waitingForYou(.idle):
            return [.text(L10n.t("activity.waiting.maybe", "looks like it is waiting for you"))]
        case .crashed:
            return [.text(L10n.t("peek.reason.crashed", "the session ended unexpectedly"))]
        case .done:
            return [.text(session.handoff?.summary ?? L10n.t("activity.done", "finished the task"))]
        case .working, .idle:
            return [.text(session.activityDescription)]
        }
    }

    private static func segments(for action: PendingAction) -> [Segment] {
        switch action.kind {
        case .run(let command): return [.text(L10n.t("peek.reason.run", "wants to run")), .code(command)]
        case .edit(let file): return [.text(L10n.t("peek.reason.edit", "wants to edit")), .code(file)]
        case .open(let host): return [.text(L10n.t("peek.reason.open", "wants to open")), .code(host)]
        case .use(let tool): return [.text(L10n.t("peek.reason.use", "wants to use")), .code(tool)]
        }
    }

    /// Up to the first ". " or newline, without the full stop. Claude Code's
    /// messages are one or two short sentences; the first one is the point.
    private static func firstSentence(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let line = text.split(separator: "\n").first.map(String.init) ?? text
        let sentence = line.components(separatedBy: ". ").first ?? line
        return sentence.hasSuffix(".") ? String(sentence.dropLast()) : sentence
    }
}
