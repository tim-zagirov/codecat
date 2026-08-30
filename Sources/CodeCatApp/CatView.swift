import SwiftUI
import CodeCatCore

/// A calm, hand-drawn orange cat that mirrors the aggregate state of every tracked
/// session. Pure function of `status`/`sessionCount` — no timers, no app-state
/// access, no stored animation flags. Every repeating motion (breathing, tail
/// sway, eye tracking, paw wave, badge pulse) is driven by its own
/// `.phaseAnimator`, scoped to the exact subview it animates. That means each
/// cycle starts the instant its view is inserted into the hierarchy — whether
/// that happens at first launch (`.sleeping`) or much later when the state
/// machine first reaches `.working`/`.waiting` — instead of depending on a single
/// `onAppear` transaction that only ever animated whatever happened to be
/// mounted at that instant.
///
/// Drawn in a ~96pt coordinate space but laid out on a larger canvas
/// (`MascotLayout.canvasSize`): the tail swish and the badge pulse reach past the
/// drawing's nominal bounds, and the panel window has no slack of its own, so
/// without that margin the window edge slices the tail off. See `MascotLayout`.
/// It reads clearly over an arbitrary desktop background: every color is a fixed,
/// opaque value (never a system/semantic color), so the cat looks the same in
/// light or dark environments instead of blending into them.
private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

struct CatView: View {
    let status: AggregateStatus
    let sessionCount: Int

    init(status: AggregateStatus, sessionCount: Int) {
        self.status = status
        self.sessionCount = sessionCount
    }

    private var bodyColor: Color {
        if case .problem = status { return Color(red: 0.55, green: 0.30, blue: 0.16) } // muted burnt umber, distinct from the resting orange but still warm
        return Color(red: 0.91, green: 0.63, blue: 0.30) // #E8A04C
    }
    private let dark = Color(red: 0.23, green: 0.16, blue: 0.09)

    private var isSleeping: Bool { if case .sleeping = status { return true }; return false }
    private var isWorking: Bool { if case .working = status { return true }; return false }
    private var isWaiting: Bool { if case .waiting = status { return true }; return false }
    private var isProblem: Bool { if case .problem = status { return true }; return false }

    var body: some View {
        ZStack {
            if isSleeping {
                sleepingCat
            } else {
                sittingCat
            }
            MascotBadge(sessionCount: sessionCount, status: status)
        }
        .frame(width: MascotLayout.canvasSize, height: MascotLayout.canvasSize)
    }

    // MARK: - Sleeping

    private var sleepingCat: some View {
        ZStack {
            // Tail curled around the front of the body.
            Capsule()
                .fill(bodyColor)
                .frame(width: 34, height: 11)
                .rotationEffect(.degrees(58))
                .offset(x: 20, y: 34)
            // Curled body: wide and low, clearly larger than and separate from the head.
            Ellipse()
                .fill(bodyColor)
                .frame(width: 60, height: 36)
                .offset(x: 6, y: 26)
                .phaseAnimator([false, true]) { content, breathePhase in
                    content.scaleEffect(y: breathePhase ? 1.04 : 0.98, anchor: .bottom)
                } animation: { _ in .easeInOut(duration: 2.4) }
            // Head rests low against the body but is offset well clear of it so
            // the two shapes read as distinct forms rather than merging.
            Circle()
                .fill(bodyColor)
                .frame(width: 30, height: 30)
                .offset(x: -22, y: 8)
            // Both ears sit on top of the head, offset relative to its position.
            ear(x: -30, y: -8, flattened: false)
            ear(x: -14, y: -10, flattened: false)
            // Closed eye: a short curved line positioned on the head, like every
            // other facial feature — never absolute canvas coordinates.
            Path { p in
                p.move(to: CGPoint(x: -4, y: 0))
                p.addQuadCurve(to: CGPoint(x: 4, y: 0), control: CGPoint(x: 0, y: 3))
            }
            .stroke(dark, lineWidth: 1.6)
            .frame(width: 8, height: 4)
            .offset(x: -22, y: 10)
            // Drifting "z z", floating up and away from the head.
            Text("z z")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(bodyColor)
                .phaseAnimator([false, true]) { content, breathePhase in
                    content.offset(x: 2, y: breathePhase ? -24 : -20)
                } animation: { _ in .easeInOut(duration: 2.4) }
        }
    }

    // MARK: - Sitting (working / waiting / done / problem)

    private var sittingCat: some View {
        ZStack {
            tailView
            Ellipse()
                .fill(bodyColor)
                .frame(width: 50, height: 52)
                .offset(y: 20)
                .phaseAnimator([false, true]) { content, breathePhase in
                    content.scaleEffect(y: breathePhase ? 1.02 : 0.99, anchor: .bottom)
                } animation: { _ in .easeInOut(duration: 2.4) }
            Circle().fill(bodyColor).frame(width: 44, height: 44).offset(y: -14)
            ear(x: -15, y: -34, flattened: isProblem)
            ear(x: 15, y: -34, flattened: isProblem)
            face
            pawView
        }
    }

    /// The tail. It only actively swishes while working; every other state
    /// holds it at a calm, fixed angle. Because the swishing branch is its own
    /// view (with its own `.phaseAnimator`), it starts a fresh cycle exactly
    /// when `isWorking` becomes true, regardless of how long the cat has
    /// already been on screen.
    private var tailView: some View {
        Group {
            if isWorking {
                Capsule()
                    .fill(bodyColor)
                    .frame(width: 34, height: 9)
                    .offset(x: 30, y: 34)
                    .phaseAnimator([false, true]) { content, tailPhase in
                        content.rotationEffect(.degrees(tailPhase ? 18 : -6), anchor: .leading)
                    } animation: { _ in .easeInOut(duration: 1.8) }
            } else {
                Capsule()
                    .fill(bodyColor)
                    .frame(width: 34, height: 9)
                    .offset(x: 30, y: 34)
                    .rotationEffect(.degrees(4), anchor: .leading)
            }
        }
    }

    /// The waving paw. Only exists while `.waiting`; its own `.phaseAnimator`
    /// begins the wave the instant it is mounted.
    private var pawView: some View {
        Group {
            if isWaiting {
                Capsule()
                    .fill(bodyColor)
                    .frame(width: 9, height: 24)
                    .offset(x: 30, y: -2)
                    .phaseAnimator([false, true]) { content, pawPhase in
                        content.rotationEffect(.degrees(pawPhase ? 28 : -12), anchor: .bottom)
                    } animation: { _ in .easeInOut(duration: 1.0) }
            }
        }
    }

    private func ear(x: CGFloat, y: CGFloat, flattened: Bool) -> some View {
        Triangle()
            .fill(bodyColor)
            .frame(width: 16, height: 14)
            // Rotate about the base (bottom-center) rather than the centroid, so the
            // tip swings down while the base stays anchored to the head. Anchor
            // `.bottom` matches Triangle's own geometry: its base spans the bottom
            // edge (maxY) and its apex is at the top (minY).
            .rotationEffect(.degrees(flattened ? (x < 0 ? -30 : 30) : 0), anchor: .bottom)
            .offset(x: x, y: y)
    }

    private var face: some View {
        ZStack {
            if isWorking {
                // Open eyes that track back and forth while working. Its own
                // phaseAnimator means the tracking starts the moment work begins.
                ZStack {
                    Circle().fill(dark).frame(width: 5, height: 5)
                        .phaseAnimator([false, true]) { content, trackPhase in
                            content.offset(x: trackPhase ? -7 : -9, y: -16)
                        } animation: { _ in .easeInOut(duration: 1.8) }
                    Circle().fill(dark).frame(width: 5, height: 5)
                        .phaseAnimator([false, true]) { content, trackPhase in
                            content.offset(x: trackPhase ? 9 : 7, y: -16)
                        } animation: { _ in .easeInOut(duration: 1.8) }
                }
            } else {
                // Content arcs, static.
                happyEye.offset(x: -8, y: -16)
                happyEye.offset(x: 8, y: -16)
            }
            Triangle()
                .fill(dark)
                .frame(width: 6, height: 4)
                .rotationEffect(.degrees(180))
                .offset(y: -8)
        }
    }

    private var happyEye: some View {
        Path { p in
            p.move(to: CGPoint(x: 0, y: 4))
            p.addQuadCurve(to: CGPoint(x: 8, y: 4), control: CGPoint(x: 4, y: 0))
        }
        .stroke(dark, lineWidth: 1.6)
        .frame(width: 8, height: 6)
    }
}
