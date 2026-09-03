import Foundation

/// Which frame to show `elapsed` seconds after the state began.
///
/// A pure function of time, with no counter and no state: the mascot's view is
/// recreated constantly (the panel opened, the skin changed, the island redrew), and
/// a movement has no business restarting on every redraw. All it needs is the moment
/// the state was entered; `AppState` knows that, and it survives any rebuild of the
/// view.
public enum SpriteTimeline {

    /// The frame at `elapsed`. `nil` only for an empty animation.
    ///
    /// A negative `elapsed` (the clock was set back) reads as "the state has just
    /// begun" — better than showing a frame from the middle of a transition.
    public static func frame(at elapsed: TimeInterval, in animation: SpriteAnimation) -> SpriteFrame? {
        var remaining = max(0, elapsed)
        for phase in animation.phases {
            // An empty or stopped phase does not eat the movement: it simply is not there.
            guard !phase.frames.isEmpty, phase.framesPerSecond > 0 else { continue }
            // With no repeat count the phase loops forever — there is nowhere further to go.
            guard let repeats = phase.repeats else {
                return phase.frames[wrappedIndex(remaining, phase)]
            }
            let duration = Double(phase.frames.count) / phase.framesPerSecond * Double(max(0, repeats))
            if remaining < duration {
                return phase.frames[wrappedIndex(remaining, phase)]
            }
            remaining -= duration
        }
        // Every phase is finite and has already played — hold on the last frame rather
        // than return to the start: the movement is over and repeating it earns nothing.
        return animation.phases.last(where: { !$0.frames.isEmpty })?.frames.last
    }

    private static func wrappedIndex(_ elapsed: TimeInterval, _ phase: SpritePhase) -> Int {
        let count = phase.frames.count
        let ticks = Int((elapsed * phase.framesPerSecond).rounded(.down))
        return ((ticks % count) + count) % count
    }
}
