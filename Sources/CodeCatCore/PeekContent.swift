import Foundation

/// What a peek says — spec §6.2: a title, one line of reason with inline code, and a
/// pill on the right. Computed here, not in the view, so every kind's wording and
/// every fallback is tested.
public struct PeekContent: Equatable, Sendable {
    public enum Pill: Equatable, Sendable {
        /// Open ↗: in the waiting tone with black text for a wait — the only coloured
        /// button on the island — white 10 % for a crash.
        case open(prominent: Bool)
        /// A done turn's first handoff chip: click opens, drag carries.
        case chip(HandoffLink)
        /// Opens the list: merged and away peeks name no single session to jump to.
        case show
        /// A done turn that handed nothing over (or the task switch is off).
        case absent
    }

    public let title: String
    public let segments: [PeekReason.Segment]
    public let pill: Pill
    /// The session a click on the line or on Open jumps to; nil for merged and away.
    public let sessionID: String?
    /// The countdown hairline's colour.
    public let tone: MascotTone

    public init(title: String, segments: [PeekReason.Segment], pill: Pill, sessionID: String?, tone: MascotTone) {
        self.title = title; self.segments = segments; self.pill = pill; self.sessionID = sessionID; self.tone = tone
    }

    /// Nil when the peek names sessions that are gone — `IslandFlow` ends such peeks,
    /// and a frame drawn in between shows nothing rather than a stale name.
    public static func make(for item: PeekItem, sessions: [Session], showsTaskText: Bool) -> PeekContent? {
        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        switch item.kind {
        case .waiting, .crashed, .done:
            guard let id = item.sessionIDs.first, let session = byID[id] else { return nil }
            return single(item.kind, session, showsTaskText: showsTaskText)
        case .merged:
            let present = item.sessionIDs.compactMap { byID[$0] }
            guard !present.isEmpty else { return nil }
            let anyWaits = present.contains { if case .waitingForYou = $0.status { return true }; return false }
            return PeekContent(title: L10n.f("peek.merged", "%d agents need you", item.sessionIDs.count),
                               segments: [.text(present.map(\.projectName).joined(separator: " · "))],
                               pill: .show, sessionID: nil, tone: anyWaits ? .waiting : .problem)
        case .away(let done, let waiting, let crashed):
            var parts: [String] = []
            if done > 0 { parts.append(L10n.f("peek.away.done", "%d done", done)) }
            if waiting > 0 { parts.append(L10n.f("peek.away.waiting", "%d waiting", waiting)) }
            if crashed > 0 { parts.append(L10n.f("peek.away.crashed", "%d crashed", crashed)) }
            let tone: MascotTone = waiting > 0 ? .waiting : (crashed > 0 ? .problem : .done)
            return PeekContent(title: L10n.t("peek.away.title", "While you were away"),
                               segments: [.text(parts.joined(separator: " · "))],
                               pill: .show, sessionID: nil, tone: tone)
        }
    }

    private static func single(_ kind: PeekItem.Kind, _ session: Session, showsTaskText: Bool) -> PeekContent {
        switch kind {
        case .crashed:
            // Fixed text, not `PeekReason.segments(for:)`: that reads the session's
            // *current* status, which can have moved on (done, working again) by the
            // time this peek is drawn — a crash peek must not leak whatever comes next.
            return PeekContent(title: session.projectName,
                               segments: [.text(L10n.t("peek.reason.crashed", "the session ended unexpectedly"))],
                               pill: .open(prominent: false), sessionID: session.id, tone: .problem)
        case .done:
            let summary = showsTaskText ? session.handoff?.summary : nil
            let chip = showsTaskText ? session.handoff?.links.first : nil
            return PeekContent(title: session.projectName,
                               segments: [.text(summary ?? L10n.t("activity.done", "finished the task"))],
                               pill: chip.map(Pill.chip) ?? .absent, sessionID: session.id, tone: .done)
        default:
            // With the task switch off the command stays private too: it can say as
            // much as the task does.
            let segments = showsTaskText ? PeekReason.segments(for: session) : [.text(session.status.title)]
            return PeekContent(title: session.projectName, segments: segments,
                               pill: .open(prominent: true), sessionID: session.id, tone: .waiting)
        }
    }
}
