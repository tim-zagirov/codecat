import SwiftUI
import CodeCatCore

/// The island's content: the cat in the left wing, the right wing in the right, and
/// between them a hole for the physical notch.
///
/// The wings are equally wide, and that is the composition's main rule. The cat is
/// an object with bulk, the right wing is a mark; they cannot be balanced with type
/// size or colour, only with geometry. While the wing was sized from the sprite, the
/// whole black shape drifted off the screen's centre and was cat-heavy.
struct IslandView: View {
    @ObservedObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    /// The tallest the menu's content may be before it scrolls — the room below the
    /// island strip. Passed straight through to `IslandMenuView` and used to cap the
    /// revealed silhouette so it never runs off the screen's bottom.
    var maxContentHeight: CGFloat = .greatestFiniteMagnitude
    var onJump: () -> Void = {}
    /// The cursor as the AppKit host sees it; every hover highlight in the menu is
    /// computed from it (see `PointerTracker`).
    let pointer: PointerTracker

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

    /// The outline at this moment — the strip, or the strip and the revealed menu.
    private var currentBody: IslandBody {
        IslandBody(width: bodyWidth, height: revealedHeight,
                   edgeRadius: IslandLayout.edgeRadius, bottomRadius: IslandLayout.cornerRadius)
    }

    var body: some View {
        VStack(spacing: 0) {
            strip
            if let menuLevel {
                IslandMenuView(appState: appState, level: menuLevel,
                               width: bodyWidth, maxContentHeight: maxContentHeight,
                               onJump: onJump)
            }
        }
        // Room for the fillets at the screen edge: they lie outside the body, so the
        // window is wider than the body by `edgeRadius` on each side while the content
        // stays exactly within the body. See `IslandLayout.edgeRadius`.
        .padding(.horizontal, IslandLayout.edgeRadius)
        .background(Color.black)
        // The rim follows the outline as the menu reveals: `currentBody` animates on
        // the reveal spring, and the stroke with it.
        .overlay(alignment: .top) {
            IslandRim(bodyShape: currentBody, tone: appState.store.aggregate.tone)
        }
        // One mask for the island and the menu at once — the shared backing. The shape
        // is drawn by a mask rather than by clipping the background: `clipShape` would
        // cut the background's rectangle, and the area outside the body (the fillets)
        // has to be painted too.
        .mask(alignment: .top) {
            IslandShape(bodyShape: currentBody)
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
        .environmentObject(pointer)
        .environment(\.islandReduceMotion, reduceMotion || Motion.reduceMotionForced)
    }

    /// The island strip: the cat in the left wing, the right wing in the right, and
    /// between them a hole for the physical notch.
    private var strip: some View {
        HStack(spacing: 0) {
            cat
                .frame(width: wingWidth, height: height)
            // The physical notch: nothing goes here, there is a hole in the panel.
            Color.clear
                .frame(width: notchWidth, height: height)
            IslandWingView(content: RightWing.content(for: appState.store.ordered,
                                                      aggregate: appState.store.aggregate.tone, now: Date()))
                .frame(width: wingWidth, height: height)
        }
        .frame(height: height)
    }

    private var cat: some View {
        MascotView(skin: appState.skin,
                   status: appState.store.aggregate,
                   indicator: appState.store.indicator,
                   drawingSize: spriteSize,
                   canvasSize: CGSize(width: spriteSize.width, height: height),
                   showsBadge: false,
                   since: appState.statusSince,
                   onLoadFailure: { [appState] skin in appState.reportSkinLoadFailure(skin) })
    }
}
