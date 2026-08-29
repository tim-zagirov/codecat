import SwiftUI
import CodeCatCore

/// A calm, hand-drawn orange cat that mirrors the aggregate state of every tracked
/// session. Pure function of `status`/`sessionCount` — no timers, no app-state
/// access. The only mutable state is animation phase, driven by SwiftUI's
/// `repeatForever` interpolation (not a `Timer`), so the view costs nothing beyond
/// what the animation system already does while it sits on screen all day.
///
/// Designed for a ~96x96pt frame (see Task 13's floating panel) and to read
/// clearly over an arbitrary desktop background: every color is a fixed, opaque
/// value (never a system/semantic color), so the cat looks the same in light or
/// dark environments instead of blending into them.
struct Triangle: Shape {
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

    @State private var breathe = false
    @State private var tailWag = false
    @State private var paw = false

    private var bodyColor: Color {
        if case .problem = status { return Color(white: 0.6) }
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
            badge
        }
        .frame(width: 96, height: 96)
        .onAppear {
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                breathe = true
            }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                tailWag = true
            }
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                paw = true
            }
        }
    }

    private var sleepingCat: some View {
        ZStack {
            Ellipse()
                .fill(bodyColor)
                .frame(width: 66, height: 44)
                .offset(y: 22)
                .scaleEffect(y: breathe ? 1.04 : 0.98, anchor: .bottom)
            Circle().fill(bodyColor).frame(width: 34, height: 34).offset(x: -18, y: 10)
            ear(x: -28, y: -6, flattened: false)
            ear(x: -10, y: -8, flattened: false)
            Path { p in
                p.move(to: CGPoint(x: 34, y: 40))
                p.addLine(to: CGPoint(x: 43, y: 40))
            }
            .stroke(dark, lineWidth: 2)
            Text("z z")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(dark.opacity(0.6))
                .offset(x: 8, y: breathe ? -18 : -14)
        }
    }

    private var sittingCat: some View {
        ZStack {
            // хвост
            Capsule()
                .fill(bodyColor)
                .frame(width: 34, height: 9)
                .offset(x: 30, y: 34)
                .rotationEffect(.degrees(isWorking ? (tailWag ? 18 : -6) : 4),
                                anchor: .leading)
            // тело
            Ellipse()
                .fill(bodyColor)
                .frame(width: 50, height: 52)
                .offset(y: 20)
                .scaleEffect(y: breathe ? 1.02 : 0.99, anchor: .bottom)
            // голова
            Circle().fill(bodyColor).frame(width: 44, height: 44).offset(y: -14)
            ear(x: -15, y: -34, flattened: isProblem)
            ear(x: 15, y: -34, flattened: isProblem)
            face
            // машущая лапа
            if isWaiting {
                Capsule()
                    .fill(bodyColor)
                    .frame(width: 9, height: 24)
                    .offset(x: 30, y: -2)
                    .rotationEffect(.degrees(paw ? 28 : -12), anchor: .bottom)
            }
        }
    }

    private func ear(x: CGFloat, y: CGFloat, flattened: Bool) -> some View {
        Triangle()
            .fill(bodyColor)
            .frame(width: 16, height: 14)
            .rotationEffect(.degrees(flattened ? (x < 0 ? -55 : 55) : 0))
            .offset(x: x, y: y + (flattened ? 5 : 0))
    }

    private var face: some View {
        ZStack {
            if isWorking {
                // открытые глаза, следят
                Circle().fill(dark).frame(width: 5, height: 5)
                    .offset(x: tailWag ? -7 : -9, y: -16)
                Circle().fill(dark).frame(width: 5, height: 5)
                    .offset(x: tailWag ? 9 : 7, y: -16)
            } else {
                // довольные дуги
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

    private var badge: some View {
        Group {
            if sessionCount > 0 && !isSleeping {
                Text("\(sessionCount)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(isWaiting ? Color.red : Color.gray.opacity(0.8)))
                    .offset(x: 34, y: -34)
                    .scaleEffect(isWaiting && paw ? 1.15 : 1.0)
            }
        }
    }
}
