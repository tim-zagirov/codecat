import SwiftUI
import CodeCatCore

/// The step the agent is on, with a counter and a thin bar: "Writing the parser ·
/// 3/5". Drawn under the task line while a session is working and has a list.
///
/// The title changes with a crossfade through a 2 px blur: two texts fading over
/// each other read as two objects, and the blur melts them into one change.
struct StepLineView: View {
    let title: String
    let done: Int
    let total: Int
    /// Panel rows print the line at 11 pt like their status line; island rows at 10.
    let demoted: Bool

    @Environment(\.menuStyle) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                ZStack(alignment: .leading) {
                    Text(title)
                        .font(.system(size: demoted ? 10 : 11))
                        .foregroundStyle(style.secondary)
                        .lineLimit(1)
                        .id(title)
                        .transition(reduceMotion ? .opacity : .blurFade)
                }
                .animation(Motion.stepTitle, value: title)
                Spacer(minLength: 0)
                Text(L10n.f("row.step.progress", "%d/%d", done, total))
                    .font(.system(size: 10))
                    .foregroundStyle(style.tertiary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(Motion.stepTitle, value: done)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(style.barTrack)
                    Capsule()
                        .fill(ToneColor.color(for: .working))
                        .frame(width: proxy.size.width * CGFloat(done) / CGFloat(max(total, 1)))
                }
            }
            .frame(height: 2)
            .animation(reduceMotion ? nil : Motion.reposition, value: done)
        }
    }
}

/// Opacity plus a small blur — the outgoing text softens as it goes, and the
/// incoming one sharpens as it arrives.
private struct BlurFade: ViewModifier {
    let radius: CGFloat
    let opacity: Double
    func body(content: Content) -> some View {
        content.blur(radius: radius).opacity(opacity)
    }
}

extension AnyTransition {
    static let blurFade = AnyTransition.modifier(
        active: BlurFade(radius: 2, opacity: 0),
        identity: BlurFade(radius: 0, opacity: 1))
}
