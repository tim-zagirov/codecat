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
            HStack(spacing: RightWing.dotSpacing) {
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

/// A session's dot: 7 pt in its tone; the waiting one pulses with a 13 pt halo drawn
/// over its neighbours. With Reduce Motion it sits still in a ring instead (§11).
///
/// One view whatever the tone: the halo and the ring are always there, shown only
/// while waiting, and the pulse is computed from the clock rather than switched on
/// by a `phaseAnimator` branch. With an `if waiting { … } else { dot }` the dot that
/// started waiting was a *new* view: captures showed the old green dot fading out
/// 3–4 pt left of the new amber one for 0.2 s, and under Reduce Motion the amber
/// dot slid into place. Now a change of tone animates colour only
/// (`Motion.toneCrossfade`).
struct SessionDotView: View {
    let tone: MascotTone
    @Environment(\.islandReduceMotion) private var reduced
    @Environment(\.islandIsOnScreen) private var onScreen

    var body: some View {
        let waiting = tone == .waiting
        let pulsing = waiting && !reduced
        // Paused unless pulsing, so the loop stops the moment no session waits — and
        // while the island is off screen.
        TimelineView(.animation(paused: !pulsing || !onScreen)) { context in
            Circle()
                .frame(width: RightWing.dotWidth, height: RightWing.dotWidth)
                .scaleEffect(pulsing ? Self.pulseScale(at: context.date) : 1)
        }
        // The halo and the ring overflow the 7 pt frame into the gaps (Tim,
        // 2026-09-30): the row lays out every dot at 7 pt. The two
        // `animation(_:body:)` scopes animate only their opacity — a value-keyed
        // `.animation` here once slid the dot 3 pt with Reduce Motion.
        .background {
            Circle()
                .frame(width: 13, height: 13)
                .animation(Motion.toneCrossfade) { $0.opacity(pulsing ? 0.3 : 0) }
            Circle().strokeBorder(lineWidth: 1.5)
                .frame(width: 13, height: 13)
                .animation(Motion.toneCrossfade) { $0.opacity(waiting && reduced ? 1 : 0) }
        }
        .animation(Motion.toneCrossfade) { $0.modifier(ToneTint(ToneColor.island(tone))) }
        .frame(width: RightWing.dotWidth, height: RightWing.dotWidth)
        // Keeps the halo and the dot one rigid unit, so the wing's `.animation(_:value:
        // dots)` moves them together and the pair stays concentric.
        .geometryGroup()
    }

    /// The pulse (§4.2, "the existing 3 s pulse"): 1 → 1.35 → 1, ease-in-out, 3 s each
    /// way, from a timestamp like the rim's lap, so a rebuild does not restart it.
    static func pulseScale(at date: Date) -> CGFloat {
        let cycle = date.timeIntervalSinceReferenceDate / (2 * Motion.pulse)
        let phase = 2 * (cycle - cycle.rounded(.down))
        let rise = phase < 1 ? phase : 2 - phase
        return 1 + 0.35 * CGFloat(UnitCurve.easeInOut.value(at: rise))
    }
}

/// Paints its content in `color`, and animates a change of it channel by channel.
/// `foregroundStyle` alone does not animate inside `animation(_:body:)`: the dot
/// that started waiting turned amber in one frame while its ring faded in.
private struct ToneTint: ViewModifier, Animatable {
    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<Double, Double>>

    init(_ color: Color) {
        let rgb = NSColor(color).usingColorSpace(.sRGB) ?? .black
        animatableData = AnimatablePair(AnimatablePair(rgb.redComponent, rgb.greenComponent),
                                        AnimatablePair(rgb.blueComponent, rgb.alphaComponent))
    }

    func body(content: Content) -> some View {
        content.foregroundStyle(Color(.sRGB, red: animatableData.first.first, green: animatableData.first.second,
                                      blue: animatableData.second.first, opacity: animatableData.second.second))
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
