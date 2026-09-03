import SwiftUI
import CodeCatCore

/// The island's content: the cat in the left wing, the counter in the right, and
/// between them a hole for the physical notch.
///
/// The wings are equally wide, and that is the composition's main rule. The cat is
/// an object with bulk, the counter is a mark; they cannot be balanced with type
/// size or colour, only with geometry. While the wing was sized from the sprite, the
/// whole black shape drifted off the screen's centre and was cat-heavy.
struct IslandView: View {
    @ObservedObject var appState: AppState
    let notchWidth: CGFloat
    let wingWidth: CGFloat
    let spriteSize: CGSize
    /// Height of the island strip — the same as the notch's height.
    let height: CGFloat
    /// Which menu to show under the island. `nil` means the strip alone.
    var menuLevel: IslandMenuLevel?
    /// The menu is closing: the silhouette travels back to the island's height on the
    /// same spring. Its content stays mounted meanwhile — otherwise there would be
    /// nothing to collapse — and is taken down once the animation has arrived.
    var isCollapsing: Bool = false
    var onJump: () -> Void = {}

    /// Height of the menu's content as the layout actually measured it, and a flag
    /// that the reveal has happened. The pair is needed together: while the height is
    /// unknown there is nothing to reveal, and starting the animation earlier would
    /// run from zero to zero.
    @State private var menuHeight: CGFloat = 0
    @State private var revealed = false

    /// A spring with no overshoot. Overshoot in the menu bar reads not as liveliness
    /// but as rattle: the shape sits flush against the screen's edge, and any overrun
    /// past the final height looks like a defect.
    static let reveal = Animation.spring(response: 0.28, dampingFraction: 1.0)

    /// How long to wait before taking the menu's content down and shrinking the
    /// window: a spring with no overshoot settles well within this. The controller
    /// knows it too.
    static let revealDuration: TimeInterval = 0.32

    /// Width of the body — without the room for the fillets.
    private var bodyWidth: CGFloat { 2 * wingWidth + notchWidth }

    /// How far the silhouette is open right now. This is the whole animation: one
    /// shape's height grows and its rounded bottom edge travels down with it. No seam,
    /// no second shape, no matching radii to each other.
    private var revealedHeight: CGFloat { height + (revealed ? menuHeight : 0) }

    var body: some View {
        VStack(spacing: 0) {
            strip
            if let menuLevel {
                IslandMenuView(appState: appState, level: menuLevel,
                               width: bodyWidth, onJump: onJump)
            }
        }
        // Room for the fillets at the screen edge: they lie outside the body, so the
        // window is wider than the body by `edgeRadius` on each side while the content
        // stays exactly within the body. See `IslandLayout.edgeRadius`.
        .padding(.horizontal, IslandLayout.edgeRadius)
        .background(Color.black)
        // One mask for the island and the menu at once — the shared backing. The shape
        // is drawn by a mask rather than by clipping the background: `clipShape` would
        // cut the background's rectangle, and the area outside the body (the fillets)
        // has to be painted too.
        .mask(alignment: .top) {
            IslandShape(bottomRadius: IslandLayout.cornerRadius)
                .frame(height: revealedHeight)
        }
        .onPreferenceChange(IslandContentHeightKey.self) { measured in
            guard measured > 0 else { return }
            if revealed {
                // Going from short to full: the reveal already happened, so travel to
                // the new height on the same spring without collapsing the session list.
                withAnimation(Self.reveal) { menuHeight = measured }
            } else {
                menuHeight = measured
                guard menuLevel != nil, !isCollapsing else { return }
                withAnimation(Self.reveal) { revealed = true }
            }
        }
        .onChange(of: isCollapsing) { _, collapsing in
            guard collapsing else { return }
            withAnimation(Self.reveal) { revealed = false }
        }
        .onChange(of: menuLevel == nil) { _, gone in
            // The content was taken down — reset without animation: the silhouette is
            // already at the island's height and there is nothing to animate.
            guard gone else { return }
            revealed = false
            menuHeight = 0
        }
    }

    /// The island strip: the cat in the left wing, the counter in the right, and
    /// between them a hole for the physical notch.
    private var strip: some View {
        HStack(spacing: 0) {
            cat
                .frame(width: wingWidth, height: height)
            // The physical notch: nothing goes here, there is a hole in the panel.
            Color.clear
                .frame(width: notchWidth, height: height)
            counter
                .frame(width: wingWidth, height: height)
        }
        .frame(height: height)
    }

    private var cat: some View {
        MascotView(skin: appState.skin,
                   status: appState.store.aggregate,
                   sessionCount: appState.store.badgeCount,
                   drawingSize: spriteSize,
                   canvasSize: CGSize(width: spriteSize.width, height: height),
                   showsBadge: false,
                   since: appState.statusSince,
                   onLoadFailure: { [appState] skin in appState.reportSkinLoadFailure(skin) })
    }

    /// The counter in a capsule rather than a bare digit.
    ///
    /// The capsule carries weight here, it does not decorate: a single glyph against a
    /// dense sprite reads as a mark, and the right-hand side visually caves in. A
    /// bounded shape evens the two sides out. A label ("1 session", "3 sessions") was
    /// dropped for a different reason: the word's width changes with the number, so
    /// the capsule would jump every time the count changed.
    @ViewBuilder
    private var counter: some View {
        let count = appState.store.badgeCount
        if count > 0 {
            HStack(spacing: 4) {
                statusDot
                // The digit is always white: the dot carries the state. A red digit next
                // to a red dot is two signals for one thing.
                Text("\(count)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .monospacedDigit()
            }
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(Color.white.opacity(0.10)))
        } else {
            // Nothing to count — but the island stays put, or there would be nothing to
            // hover. A dot without the capsule: an empty shape earns nothing.
            Circle()
                .fill(Color.white.opacity(0.35))
                .frame(width: 6, height: 6)
        }
    }

    /// The dot's colour repeats the status colours in the session list exactly: a dot
    /// on the island and a dot in a menu row have to mean the same thing, or the colour
    /// system falls apart into two.
    private var statusDot: some View {
        Circle()
            .fill(color(for: appState.store.aggregate))
            .frame(width: 6, height: 6)
    }

    private func color(for status: AggregateStatus) -> Color {
        switch status {
        case .working: return .green
        case .waiting: return .orange
        case .done: return .blue
        case .problem: return .red
        case .sleeping: return Color.white.opacity(0.35)
        }
    }
}

/// The island's silhouette: concave fillets against the screen's top edge, rounded
/// corners at the bottom. All the geometry lives in `IslandLayout.silhouettePath`;
/// this is only the SwiftUI wrapper.
///
/// `animatableData` is the bottom radius: it changes as the menu reveals, and
/// without this the corners would snap while the shape itself travelled on a spring.
/// The fillets at the edge are not animated: the screen's edge does not move.
struct IslandShape: Shape {
    var bottomRadius: CGFloat

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        Path(IslandLayout.silhouettePath(in: rect, bottomRadius: bottomRadius))
    }
}
