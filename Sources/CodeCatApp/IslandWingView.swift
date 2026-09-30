import SwiftUI
import CodeCatCore

/// The compact island's right wing — spec §4.2: live data in the aggregate's type and
/// colour. What to show is decided by `RightWing`; this only draws it.
struct IslandWingView: View {
    let content: RightWing
    @Environment(\.islandReduceMotion) private var reduced

    var body: some View {
        switch content {
        case .empty:
            // The plate is quiet: 0.4's grey dot is gone.
            Color.clear.frame(width: 1, height: 1)
        case .progress(let done, let total):
            HStack(spacing: 5) {
                number(L10n.f("row.step.progress", "%d/%d", done, total), .working)
                ProgressRing(done: done, total: total, tone: .working)
            }
        case .elapsed(let text):
            number(text, .working)
        case .check:
            CheckDisc(tone: .done)
        case .dot(let tone):
            SessionDotView(tone: tone)
        case .dots(let dots):
            // Keyed by session, so a dot that changes tone recolours and slides to
            // its new place instead of another dot fading in where it was.
            HStack(spacing: 5) {
                ForEach(dots) { SessionDotView(tone: $0.tone) }
            }
            .animation(reduced ? nil : Motion.reposition, value: dots)
        case .count(let tone, let count):
            HStack(spacing: 5) {
                SessionDotView(tone: tone)
                number("\(count)", tone)
            }
        }
    }

    private func number(_ text: String, _ tone: MascotTone) -> some View {
        Text(text)
            .font(IslandPalette.numberFont)
            .monospacedDigit()
            .foregroundStyle(ToneColor.island(tone))
            .contentTransition(.numericText())
    }
}

/// A session's dot: 7 pt in its tone. The waiting one pulses inside a 13 pt halo —
/// with Reduce Motion it sits still in a ring instead (§11).
struct SessionDotView: View {
    let tone: MascotTone
    @Environment(\.islandReduceMotion) private var reduced

    var body: some View {
        let color = ToneColor.island(tone)
        let dot = Circle().fill(color).frame(width: 7, height: 7)
        ZStack {
            if tone == .waiting {
                if reduced {
                    Circle().strokeBorder(color, lineWidth: 1.5).frame(width: 13, height: 13)
                    dot
                } else {
                    Circle().fill(color.opacity(0.3)).frame(width: 13, height: 13)
                    dot.phaseAnimator([false, true]) { content, pulse in
                        content.scaleEffect(pulse ? 1.35 : 1)
                    } animation: { _ in Motion.pulse }
                }
            } else {
                dot
            }
        }
        .frame(width: tone == .waiting ? 13 : 7, height: 13)
        // Isolates the halo-plus-dot pair as one rigid geometry unit. Without it,
        // the ancestor animations that key off `dots`/`tone` (this view's own
        // `.animation(_:value: tone)` below, and the wing's
        // `.animation(_:value: dots)` around the `HStack`) leaked into
        // `phaseAnimator`'s internal phase change, and the *animated* dot child
        // was laid out independently of its static halo sibling — each render
        // pass could place it anywhere up to the width of the notch away, not
        // merely a few points off. `geometryGroup()` here, wrapping both circles
        // together before either `.animation` modifier sees them, keeps the pair
        // concentric no matter which ancestor value changes next.
        .geometryGroup()
        .animation(Motion.toneCrossfade, value: tone)
    }
}

/// Steps done of steps planned, as a 16 pt ring from 12 o'clock. A finished step
/// sweeps the arc on `Motion.reposition`; with Reduce Motion the arc jumps to its new
/// length, as the dots do (§11: no springs) — a capture with the flag forced showed
/// the arc sweeping for 0.27 s.
struct ProgressRing: View {
    let done: Int
    let total: Int
    let tone: MascotTone
    @Environment(\.islandReduceMotion) private var reduced

    var body: some View {
        let fraction = CGFloat(min(done, total)) / CGFloat(max(total, 1))
        ZStack {
            Circle().inset(by: 1.25).stroke(IslandPalette.ringTrack, lineWidth: 2.5)
            Circle().inset(by: 1.25)
                .trim(from: 0, to: fraction)
                .stroke(ToneColor.island(tone), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 16, height: 16)
        .animation(reduced ? nil : Motion.reposition, value: fraction)
    }
}

/// A finished turn: a 16 pt disc in the tone with a white check.
struct CheckDisc: View {
    let tone: MascotTone

    var body: some View {
        Circle()
            .fill(ToneColor.island(tone))
            .frame(width: 16, height: 16)
            .overlay(Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white))
    }
}
