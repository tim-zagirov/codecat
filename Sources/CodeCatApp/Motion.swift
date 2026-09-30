import SwiftUI
import CodeCatCore

/// Every duration and curve the island uses, in one place, so the numbers in the
/// design spec (§11) and the numbers on screen are the same numbers.
///
/// The island is seen hundreds of times a day, so nothing here loops except the two
/// requests for attention — the waiting dot's pulse and the rim's lap (`RimLight`);
/// everything else moves once, on change. Springs carry the shape; opacity and blur
/// carry the content; and the spring that closes has no bounce: overshoot at the
/// screen's edge reads as rattle, not life.
enum Motion {
    // MARK: The shape (§4.3, §5.2)

    /// The cursor touched the island: it grows a little before it opens.
    static let hoverInhale = Animation.interactiveSpring(response: 0.38, dampingFraction: 0.8)
    /// How long the cursor rests on the island before it opens; adjustable (§5.1).
    static let hoverDelayDefault: TimeInterval = 0.3
    static let hoverDelayRange: ClosedRange<TimeInterval> = 0.15...1.0
    static let openSpring = Animation.spring(response: 0.42, dampingFraction: 0.8)
    static let closeSpring = Animation.spring(response: 0.45, dampingFraction: 1.0)
    /// How long `closeSpring` takes to settle — after it, the window shrinks back.
    static let closeSpringSettle: TimeInterval = 0.5

    // MARK: The content (§5.2)

    static let contentInDuration: TimeInterval = 0.25
    /// ≈ 60 % of the open spring's travel: content arriving earlier is squeezed by a
    /// shape that is still growing.
    static let contentInDelay: TimeInterval = 0.18
    static let contentStagger: TimeInterval = 0.03
    static let contentOutDuration: TimeInterval = 0.12
    static let contentOut = Animation.easeOut(duration: contentOutDuration)
    /// The content's blur returning to 20 pt after it has faded out: a step, once the
    /// fade is over, so the way out is opacity only.
    static let blurReset = Animation.linear(duration: 0.01).delay(contentOutDuration)
    /// From "close" to a settled compact shape: the content fades, then the spring.
    static var closeSettle: TimeInterval { contentOutDuration + closeSpringSettle }

    // MARK: Colour and small things

    /// Rim, bloom and dot colour changes.
    static let toneCrossfade = Animation.easeOut(duration: 0.25)
    /// Dots and bars moving, a list growing by a row.
    static let reposition = Animation.spring(response: 0.28, dampingFraction: 1.0)
    /// The waiting dot's pulse.
    static let pulse = Animation.easeInOut(duration: 3.0)
    static let stepTitle = Animation.easeOut(duration: 0.20)
    static let chipAppear = Animation.easeOut(duration: 0.20)
    static let chipStagger: TimeInterval = 0.04
    static let chipPress = Animation.easeOut(duration: 0.12)

    // MARK: Reduce Motion (§11)

    /// Every spring becomes a 0.2 s cross-fade of the final shape.
    static let reducedCrossfade = Animation.easeInOut(duration: 0.2)
    static func open(reduced: Bool) -> Animation { reduced ? reducedCrossfade : openSpring }
    static func close(reduced: Bool) -> Animation { reduced ? reducedCrossfade : closeSpring }
    /// Item `index` of the list arriving: after the spring has mostly opened, 30 ms
    /// after the item above it. Reduced: all at once, no delay.
    static func contentIn(index: Int, reduced: Bool) -> Animation {
        reduced ? reducedCrossfade
            : .easeOut(duration: contentInDuration).delay(contentInDelay + contentStagger * Double(index))
    }
    /// `--demo-reduce-motion`: captures of the reduced island without touching the
    /// system setting.
    static let reduceMotionForced = CommandLine.arguments.contains("--demo-reduce-motion")
}

private struct IslandReduceMotionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The system's Reduce Motion, or `--demo-reduce-motion`. Set once at the
    /// island's root; everything on the island reads this, not
    /// `accessibilityReduceMotion`, so a capture can force it.
    var islandReduceMotion: Bool {
        get { self[IslandReduceMotionKey.self] }
        set { self[IslandReduceMotionKey.self] = newValue }
    }
}

/// How the open island's content arrives and leaves (§5.2): each item from a 20 pt
/// blur and zero opacity on the open spring's tail, 30 ms after the one above it;
/// everything together and faster on the way out, before the shape closes.
///
/// The way out is opacity only (§11 `contentOut`): the blur goes back to 20 pt in
/// one step once the content is invisible, ready for the next opening. Animated
/// together with the fade, the list visibly blurred as it left.
struct ContentReveal: ViewModifier {
    let visible: Bool
    var index: Int = 0
    @Environment(\.islandReduceMotion) private var reduced

    func body(content: Content) -> some View {
        let arrive = Motion.contentIn(index: index, reduced: reduced)
        content
            .animation(visible ? arrive : Motion.blurReset) {
                $0.blur(radius: visible || reduced ? 0 : 20)
            }
            .opacity(visible ? 1 : 0)
            .animation(visible ? arrive : Motion.contentOut, value: visible)
    }
}
