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

    /// The open island's header, right of the notch (spec §5.3): §4.2 in its dots
    /// form only — the ring, the elapsed time and the check are the compact wing's
    /// shorthand, and the cards below say the rest. So one session is its dot, two to
    /// four a dot each, five or more one dot in the aggregate tone and the count.
    ///
    /// Four dots give way to the count too when their row is wider than `room`
    /// (`IslandLayout.headerDotsRoom`). The row is laid out from "•••" leftwards. The
    /// header used `store.dots` as is before this: six sessions put the first dot
    /// 1.5 pt under the notch, and seven or more ran further under it.
    public static func header(for ordered: [Session], aggregate: MascotTone, room: CGFloat) -> RightWing {
        let dots = ordered.compactMap { $0.status == .idle ? nil : SessionDot(id: $0.id, tone: $0.status.tone) }
        switch dots.count {
        case 0:
            return .empty
        case 1...4 where rowWidth(dots) <= room:
            return .dots(dots)
        default:
            return .count(aggregate, dots.count)
        }
    }

    /// A dot's width in a row, whatever its tone. A waiting dot's 13 pt halo is drawn
    /// over the gaps around it rather than beside it (Tim, 2026-09-30): laid out at
    /// 13 pt, four waiting sessions were 67 pt and fell back to a count.
    public static let dotWidth: CGFloat = 7
    /// The gap between dots in a row (§4.2).
    public static let dotSpacing: CGFloat = 5
    /// How far a waiting dot's halo reaches past its dot on each side: (13 − 7) / 2.
    public static let haloOverhang: CGFloat = 3

    /// How wide a row of `dots` is on screen: the dots, the gaps, and a halo sticking
    /// out at either end — the one at the start is what could reach under the notch.
    public static func rowWidth(_ dots: [SessionDot]) -> CGFloat {
        guard let first = dots.first, let last = dots.last else { return 0 }
        let row = dotWidth * CGFloat(dots.count) + dotSpacing * CGFloat(dots.count - 1)
        return row + (first.tone == .waiting ? haloOverhang : 0) + (last.tone == .waiting ? haloOverhang : 0)
    }

    /// "4m", "1h": the wing has room for three characters, not for "4 min".
    public static func elapsedText(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds)) / 60
        if minutes < 1 { return L10n.t("wing.elapsed.fresh", "<1m") }
        if minutes < 60 { return L10n.f("wing.elapsed.minutes", "%dm", minutes) }
        return L10n.f("wing.elapsed.hours", "%dh", minutes / 60)
    }
}
