import SwiftUI

/// Every duration and curve the new island surfaces use, in one place, so the
/// numbers in the design spec (§8) and the numbers on screen are the same numbers.
///
/// The rules behind them: the island is seen hundreds of times a day, so nothing
/// here loops (the waiting pulse is the one exception, and it is a request for
/// attention); everything animates once, on change, and never longer than 300 ms;
/// enter curves are ease-out because the first frames are the ones being watched.
enum Motion {
    /// Tone glow and dot colour changes.
    static let toneCrossfade = Animation.easeOut(duration: 0.25)
    /// A new tone's single bloom — scale 0.9 → 1 and opacity 0 → 1 — measured from
    /// `AppState.statusSince`, so a rebuilt view does not replay it.
    static let bloomDuration: TimeInterval = 0.25
    /// Repositioning and any height change: the island's own reveal spring, no
    /// overshoot (see `IslandView.reveal`).
    static var reposition: Animation { IslandView.reveal }
    static let stepTitle = Animation.easeOut(duration: 0.20)
    static let chipAppear = Animation.easeOut(duration: 0.20)
    static let chipStagger: TimeInterval = 0.04
    static let chipPress = Animation.easeOut(duration: 0.12)
    static let headTint = Animation.easeOut(duration: 0.30)
    /// The one loop: the waiting dot, the same cycle the badge has always used.
    static let pulse = Animation.easeInOut(duration: 3.0)

    /// Ease-out cubic for a value driven by time rather than by SwiftUI.
    static func easeOut(_ progress: Double) -> Double {
        let p = min(1, max(0, progress))
        return 1 - pow(1 - p, 3)
    }
}
