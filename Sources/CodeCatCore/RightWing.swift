import Foundation

/// What the compact island's right wing shows — spec §4.2. Live data, never a logo:
/// one session's plan or age, a check when it is done, a dot per session for a few,
/// a count for many. The population is the one the dots have always had — every
/// session but the idle ones — in list order, so the wing reads left to right like
/// the list below it.
public enum RightWing: Equatable, Sendable {
    case empty
    case progress(done: Int, total: Int)
    case elapsed(String)
    case check
    case dot(MascotTone)
    case dots([SessionDot])
    case count(MascotTone, Int)

    /// - Parameters:
    ///   - ordered: `SessionStore.ordered`.
    ///   - aggregate: the cat's tone (`AggregateStatus.tone`), which colours the count.
    public static func content(for ordered: [Session], aggregate: MascotTone, now: Date) -> RightWing {
        let active = ordered.filter { $0.status != .idle }
        switch active.count {
        case 0:
            return .empty
        case 1:
            let session = active[0]
            switch session.status {
            case .working:
                if let progress = session.stepProgress {
                    return .progress(done: progress.done, total: progress.total)
                }
                return .elapsed(elapsedText(now.timeIntervalSince(session.startedAt)))
            case .done:
                return .check
            default:
                return .dot(session.status.tone)
            }
        case 2...4:
            return .dots(active.map { SessionDot(id: $0.id, tone: $0.status.tone) })
        default:
            return .count(aggregate, active.count)
        }
    }

    /// "4m", "1h": the wing has room for three characters, not for "4 min".
    public static func elapsedText(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds)) / 60
        if minutes < 1 { return L10n.t("wing.elapsed.fresh", "<1m") }
        if minutes < 60 { return L10n.f("wing.elapsed.minutes", "%dm", minutes) }
        return L10n.f("wing.elapsed.hours", "%dh", minutes / 60)
    }
}
