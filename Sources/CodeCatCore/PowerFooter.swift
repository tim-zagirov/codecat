import Foundation

/// The expanded island's footer — spec §5.5: whether the Mac is being kept awake, and
/// by how many agents; how long until it may sleep; whether closed-lid mode is on.
/// Shown only when there is something to say. The MVP spec promised this and 0.4
/// never showed it.
public struct PowerFooter: Equatable, Sendable {
    public enum Left: Equatable, Sendable {
        case awake(agents: Int)
        case sleepsIn(minutes: Int)
    }

    public let left: Left?
    public let lidOn: Bool

    public init(left: Left?, lidOn: Bool) {
        self.left = left
        self.lidOn = lidOn
    }

    public static let none = PowerFooter(left: nil, lidOn: false)

    public var isEmpty: Bool { left == nil && !lidOn }

    /// The deadline is checked before `isHolding`: during the grace period both are
    /// set (handover contract 6). The remaining time is clamped at zero — the 15 s
    /// maintenance tick can leave the deadline in the past — and rounded up, so the
    /// footer never says "0 min" while the assertion is still held.
    public static func make(isHolding: Bool, releaseDeadline: Date?, workingCount: Int,
                            lidModeOn: Bool, now: Date) -> PowerFooter {
        let left: Left?
        if let deadline = releaseDeadline {
            let remaining = max(0, deadline.timeIntervalSince(now))
            left = .sleepsIn(minutes: Int((remaining / 60).rounded(.up)))
        } else if isHolding {
            left = .awake(agents: workingCount)
        } else {
            left = nil
        }
        return PowerFooter(left: left, lidOn: lidModeOn)
    }

    public var leftText: String? {
        switch left {
        case .awake(let agents) where agents == 1:
            return L10n.t("footer.power.awake.one", "Mac stays awake — 1 agent working")
        case .awake(let agents):
            return L10n.f("footer.power.awake", "Mac stays awake — %d agents working", agents)
        case .sleepsIn(let minutes) where minutes == 0:
            return L10n.t("footer.power.sleep.now", "Mac can sleep now")
        case .sleepsIn(let minutes):
            return L10n.f("footer.power.sleep", "Mac can sleep in %d min", minutes)
        case nil:
            return nil
        }
    }
}
