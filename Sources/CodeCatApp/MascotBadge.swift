import SwiftUI
import CodeCatCore

/// The session-count badge, shared by every mascot skin. It lives outside `CatView`
/// because a sprite skin must show exactly the same badge, in exactly the same
/// place: with five states mapped onto packs that have as few as three poses, the
/// badge is often the only thing telling two states apart.
///
/// Opaque fill (never `.opacity(...)`) plus a light stroke so the badge stays
/// legible whether the desktop behind the transparent panel is light or dark. A
/// `Capsule` renders as a circle for the single-digit case (equal width and height)
/// and grows horizontally for two- or three-digit counts instead of clipping a
/// fixed-size circle.
struct MascotBadge: View {
    let sessionCount: Int
    let status: AggregateStatus

    private var isSleeping: Bool { if case .sleeping = status { return true }; return false }
    private var isWaiting: Bool { if case .waiting = status { return true }; return false }

    var body: some View {
        Group {
            if sessionCount > 0 && !isSleeping {
                if isWaiting {
                    // Waiting stays the most attention-grabbing state: opaque red,
                    // plus a gentle pulse so it reads as needing input.
                    content(fill: Color(red: 0.86, green: 0.15, blue: 0.15))
                        .phaseAnimator([false, true]) { content, pulsePhase in
                            content.scaleEffect(pulsePhase ? 1.15 : 1.0)
                        } animation: { _ in .easeInOut(duration: 1.0) }
                } else {
                    content(fill: Color(white: 0.32))
                }
            }
        }
    }

    private func content(fill: Color) -> some View {
        Text("\(sessionCount)")
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 4)
            .frame(minWidth: 18, minHeight: 18)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5))
            .offset(x: 34, y: -34)
    }
}
