import Foundation
import CodeCatCore

/// How long a session has been at it, phrased for its status — shared by the island's
/// cards and the floating panel's rows, which used to keep their own copies.
enum SessionTime {
    /// The duration each row shows, phrased to match what the session is doing. The
    /// old version always computed `lastActivity - startedAt`, which freezes the
    /// instant a session stops being active: a waiting session read "0 min" and a
    /// stopped one "running for 0 min", both nonsense. Now the clock reflects status.
    /// "now" is read from `Date()` at render; the app ticks `objectWillChange` every
    /// 15 s, so the value keeps counting up on its own.
    ///
    /// - working / idle: how long since it started (`now - startedAt`) — a plain span.
    /// - waiting: how long it has been waiting on you (`now - lastActivity`) → "waiting …".
    /// - done / crashed: how long ago it last did anything (`now - lastActivity`) → "… ago".
    ///
    /// Under a minute every status reads a bare "just now": "just now ago" and
    /// "waiting just now" are not English, and the first of them shipped once.
    static func text(for session: Session, now: Date = Date()) -> String {
        let justNow = L10n.t("duration.just.now", "just now")
        switch session.status {
        case .working, .idle:
            return span(from: session.startedAt, to: now) ?? justNow
        case .waitingForYou:
            guard let elapsed = span(from: session.lastActivity, to: now) else { return justNow }
            return L10n.f("duration.waiting", "waiting %@", elapsed)
        case .done, .crashed:
            guard let elapsed = span(from: session.lastActivity, to: now) else { return justNow }
            return L10n.f("duration.ago", "%@ ago", elapsed)
        }
    }

    /// A bare elapsed span in whole minutes, floored at zero so a slight clock skew
    /// never prints a negative minute count; nil under a minute.
    private static func span(from start: Date, to now: Date) -> String? {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        let m = seconds / 60
        if m == 0 {
            return nil
        }
        return m < 60
            ? L10n.f("duration.minutes", "%d min", m)
            : L10n.f("duration.hours.minutes", "%dh %dm", m / 60, m % 60)
    }
}
