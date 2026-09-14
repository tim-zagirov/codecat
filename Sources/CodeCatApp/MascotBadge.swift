import SwiftUI
import CodeCatCore

/// The state badge, shared by every mascot skin. It lives outside `CatView` because a
/// sprite skin must show exactly the same badge, in exactly the same place: with five
/// states mapped onto packs that have as few as three poses, the badge is often the
/// only thing telling two states apart.
///
/// It renders from `SessionStore.indicator` — the same source the island counter uses
/// — so the number and the colour describe one population and one state, and can never
/// disagree again. The colour vocabulary is the R1 one, byte-identical to the session
/// row dots and the island counter: working green, waiting orange, problem red, done
/// blue. A crash never hides live work: `crashedMarker` adds a small red dot trailing
/// the count rather than replacing it.
///
/// Opaque fill (never `.opacity(...)`) plus a light stroke so the badge stays legible
/// whether the desktop behind the transparent panel is light or dark. A `Capsule`
/// renders as a circle for the single-digit case (equal width and height) and grows
/// horizontally for two- or three-digit counts instead of clipping a fixed-size circle.
struct MascotBadge: View {
    let indicator: MascotIndicator

    private var isWaiting: Bool { indicator.tone == .waiting }

    var body: some View {
        Group {
            // Nothing to show for a sleeping cat: an empty badge, exactly as before.
            if indicator.tone != .sleeping {
                if isWaiting {
                    // Waiting is the state that needs the user's input, so it keeps the
                    // pulse that draws the eye. C6: a 3 s cycle (not 1 s) makes it a
                    // calm breath rather than a nag that never lets up — no timer, just
                    // a slower ease.
                    content
                        .phaseAnimator([false, true]) { content, pulsePhase in
                            content.scaleEffect(pulsePhase ? 1.15 : 1.0)
                        } animation: { _ in .easeInOut(duration: 3.0) }
                } else {
                    content
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if indicator.count > 0 {
                HStack(spacing: 3) {
                    // The digit is always white against the tone-coloured fill: the
                    // fill carries the state.
                    Text("\(indicator.count)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .monospacedDigit()
                    if indicator.crashedMarker {
                        // A crash never blanks the running count — a red mark trails it
                        // so a dead session is visible next to the ones still working.
                        Circle().fill(color(for: .problem)).frame(width: 6, height: 6)
                    }
                }
                .padding(.horizontal, 4)
                .frame(minWidth: 18, minHeight: 18)
                .background(Capsule().fill(color(for: indicator.tone)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5))
            } else {
                // Done carries no number (nothing is running) — just a small coloured
                // dot with the same stroke, so a finished cat is still marked.
                Circle()
                    .fill(color(for: indicator.tone))
                    .frame(width: 14, height: 14)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5))
            }
        }
        // Placement is the composing view's job now: `SpriteMascotView` and `CatView`
        // pin this badge to the canvas's top-trailing corner (`.frame(maxWidth:
        // .infinity, maxHeight: .infinity, alignment: .topTrailing)` + `.padding(6)`),
        // so it sits in the corner regardless of pose height instead of the old fixed
        // `.offset(x: 34, y: -34)` from the canvas centre, which landed on the head of
        // the taller poses.
    }

    /// The R1 colour vocabulary — the same literals the session row dots and the
    /// island counter use, so all three surfaces are byte-identical.
    private func color(for tone: MascotTone) -> Color {
        switch tone {
        case .working: return .green
        case .waiting: return .orange
        case .done: return .blue
        case .problem: return .red
        case .sleeping: return Color.white.opacity(0.35)
        }
    }
}
