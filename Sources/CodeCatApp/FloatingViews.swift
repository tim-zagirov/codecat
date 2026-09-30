import SwiftUI
import CodeCatCore

/// What the floating cat's windows show and the numbers they are drawn with, shared
/// by `FloatingController`, which decides, and the views, which draw.
final class FloatingModel: ObservableObject {
    @Published var presentation: IslandPresentation = .compact
    @Published var peekHold: IslandPresenter.PeekHold?
    /// The open panel's shape — the peek capsule or the list's panel, as placed
    /// (`FloatingLayout`) — and how it gets there.
    @Published var panelShape = PanelShape(size: .zero, change: .none, revision: 0)
    /// The list opened above the cat (decision 9). Never during a peek: its capsule is
    /// always under the cat.
    @Published var panelIsAbove = false
    /// The tallest the panel may be on this screen: the larger of the rooms below and
    /// above the cat. The list reports its natural height up to this less the
    /// panel's padding; capped by the panel's current height instead, it could never
    /// grow past the first height it was placed at.
    @Published var listMaxHeight: CGFloat = 0
    /// False while the cat's window is off screen, so the rim's lap and the waiting
    /// dot's pulse stop ticking.
    @Published var isOnScreen = true
    /// The cursor is on the cat: it lifts by 2 pt.
    @Published var catHovered = false
    var onJump: () -> Void = {}
    var onShow: () -> Void = {}
    var onConnect: () -> Void = {}
    /// The list's natural height, measured.
    var onListHeight: (CGFloat) -> Void = { _ in }
}

/// The open panel's shape, as the controller placed it, and how the view gets there
/// (spec §9: "on the §5.2 springs"). The panel's window is `size` plus
/// `FloatingLayout.margin` on every side; rectangles are in the shape's own space,
/// top-left origin, the window's margin left out.
struct PanelShape: Equatable {
    enum Change: Equatable {
        /// Takes the new size at once: a list that was measured again, a peek
        /// replacing a peek, a panel that is not visible yet.
        case none
        /// Springs from where it is: a peek turning into a list below the cat, which
        /// shares the peek's top edge and sides.
        case spring
        /// Starts at this rectangle and springs to its own: the resting capsule for
        /// a shape that opens under the cat, a strip at the bottom centre for a list
        /// above it, which the resting capsule is not inside.
        case grow(from: CGRect)
    }
    let size: CGSize
    let change: Change
    /// Counts the grows, so two alike in a row are still two changes.
    let revision: Int
}

/// A black capsule with the island's rim along its whole edge and its bloom (spec
/// §9): the floating cat's plate, its peek, and the list's panel all use it.
struct CapsuleSurface: View {
    let size: CGSize
    let radius: CGFloat
    let tone: MascotTone
    var boost: Double = 1
    var bloom: RimLight.Bloom = RimLight.bloom(for: .compact)
    @Environment(\.islandReduceMotion) private var reduced
    @Environment(\.islandIsOnScreen) private var onScreen

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape
            .fill(Color.black)
            .shadow(color: tone == .sleeping ? .clear : ToneColor.island(tone).opacity(bloom.opacity),
                    radius: bloom.radius, x: 0, y: bloom.y)
            .overlay {
                if tone != .sleeping {
                    TimelineView(.animation(paused: tone != .waiting || reduced || !onScreen)) { context in
                        let color = ToneColor.island(tone)
                        let stops = RimLight.stops(highlight: RimLight.highlight(tone: tone, at: context.date,
                                                                                 reduceMotion: reduced),
                                                   boost: boost).map {
                            Gradient.Stop(color: RimStroke.rimColor(color, towardWhite: $0.white).opacity($0.opacity),
                                          location: $0.location)
                        }
                        shape.inset(by: 0.75)
                            .stroke(LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing),
                                    lineWidth: IslandLayout.rimWidth)
                    }
                }
            }
            .frame(width: size.width, height: size.height)
            .animation(Motion.toneCrossfade, value: tone)
    }
}

/// The cat window: the cat standing on its capsule, the right wing's live data on the
/// capsule's right half (Figma 06 "At rest"). While the peek or a list below is open
/// the capsule makes way for them and the cat stands on theirs.
@MainActor
struct FloatingCatView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var model: FloatingModel
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    var body: some View {
        let tone = appState.store.aggregate.tone
        ZStack(alignment: .topLeading) {
            // Open below, the cat stands on the panel's edge and the capsule makes
            // way; open above (the default corner, decision 9), the panel is over the
            // cat and the capsule stays under its feet.
            if !model.presentation.isOpen || model.panelIsAbove {
                CapsuleSurface(size: FloatingLayout.capsule, radius: FloatingLayout.capsuleRadius, tone: tone)
                    .overlay(alignment: .trailing) {
                        IslandWingView(content: RightWing.content(for: appState.store.ordered, aggregate: tone,
                                                                  now: Date()))
                            .padding(.trailing, 16)
                    }
                    .offset(x: FloatingLayout.capsuleRect.minX, y: FloatingLayout.capsuleRect.minY)
                    .transition(.opacity)
            }
            MascotView(skin: appState.skin, status: appState.store.aggregate,
                       canvasSize: FloatingLayout.catCanvas, since: appState.statusSince,
                       onLoadFailure: { [appState] skin in appState.reportSkinLoadFailure(skin) })
                .frame(width: FloatingLayout.catCanvas.width, height: FloatingLayout.catCanvas.height)
                // A whole-pixel lift says the cat can be pressed; scaling would resample
                // the pixel art. Still under Reduce Motion.
                .offset(x: FloatingLayout.catCanvasRect.minX,
                        y: FloatingLayout.catCanvasRect.minY - (model.catHovered && !systemReduceMotion ? 2 : 0))
                .animation(.spring(response: 0.25, dampingFraction: 0.6), value: model.catHovered)
        }
        .frame(width: FloatingLayout.catWindowSize.width, height: FloatingLayout.catWindowSize.height,
               alignment: .topLeading)
        .environment(\.islandReduceMotion, systemReduceMotion || Motion.reduceMotionForced)
        .environment(\.islandIsOnScreen, model.isOnScreen)
        .environment(\.colorScheme, .dark)
        .animation(Motion.contentOut, value: model.presentation.isOpen)
    }
}

/// The panel next to the cat: the peek capsule (300 × 44, Figma 06 "Peek") or the
/// list in a 300 pt panel, both black with the rim (spec §9). It fills its window,
/// which the controller sizes to the shape plus `FloatingLayout.margin` for the bloom.
///
/// The shape is drawn at `drawn`, which trails the controller's `panelShape`: a
/// new shape starts at the resting capsule's rectangle and springs to its own, as the
/// island's does from its strip.
struct FloatingPanelView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var model: FloatingModel
    /// The host's pointer: the cards' hover reads it (`onHoverRegion`), as on the island.
    let pointer: PointerTracker
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    /// Above the first card, and in all: 14 above, 10 below.
    static let topPadding: CGFloat = 14
    static let padding: CGFloat = 24
    /// The peek's line, 18 pt in from the capsule's left and 10 from its right
    /// (Figma 06 "Peek").
    static let peekLeading: CGFloat = 18
    static let peekTrailing: CGFloat = 10

    @State private var drawn: CGRect = .zero
    /// Drives `ContentReveal`: false until the shape starts growing.
    @State private var contentVisible = false

    private var reduced: Bool { systemReduceMotion || Motion.reduceMotionForced }

    var body: some View {
        let size = model.panelShape.size
        let peek = peekItem
        ZStack(alignment: .topLeading) {
            surface
            content(size: size, peek: peek)
                .mask(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: Self.radius(for: drawn.size), style: .continuous)
                        .frame(width: drawn.width, height: drawn.height)
                        .offset(x: drawn.minX, y: drawn.minY)
                        // As on the island: under Reduce Motion the clip takes the
                        // final shape at once rather than growing through
                        // intermediate sizes over content that is already fading in.
                        .transaction { if reduced { $0.animation = nil } }
                }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .onPreferenceChange(IslandContentHeightKey.self) { model.onListHeight($0 + Self.padding) }
        .onChange(of: model.panelShape, initial: true) { _, shape in apply(shape) }
        .padding(FloatingLayout.margin)
        // Top-left, not centred: the window and the view do not change size in the
        // same render, and a centred root would jump by half the difference.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environmentObject(pointer)
        .environment(\.islandReduceMotion, reduced)
        .environment(\.colorScheme, .dark)
    }

    /// With Reduce Motion a change of shape is a 0.2 s cross-fade between the old and
    /// the new outline (§11), as on the island: the `id` swaps the surface, the
    /// transition fades it.
    private var surface: some View {
        CapsuleSurface(size: drawn.size, radius: Self.radius(for: drawn.size),
                       tone: appState.store.aggregate.tone,
                       bloom: RimLight.bloom(for: model.presentation))
            .offset(x: drawn.minX, y: drawn.minY)
            .id(reduced ? AnyHashable([drawn.minX, drawn.minY, drawn.width, drawn.height]) : AnyHashable(0))
            .transition(.opacity)
    }

    /// The resting capsule's 13 pt at its size, 22 pt for the peek and the list.
    private static func radius(for size: CGSize) -> CGFloat {
        min(FloatingLayout.panelRadius, size.height / 2)
    }

    /// The list stays mounted under a peek, invisible and not hit-testable, so it is
    /// measured: a peek that becomes the list opens straight at the list's height,
    /// as on the island.
    private func content(size: CGSize, peek: PeekItem?) -> some View {
        ZStack(alignment: .topLeading) {
            // The list's own maximum is the room on screen, so it reports its natural
            // height (`listMaxHeight`); the scroll view never outgrows the panel.
            IslandExpandedView(appState: appState, visible: contentVisible && model.presentation == .expanded,
                               maxHeight: max(0, model.listMaxHeight - Self.padding),
                               width: FloatingLayout.panelWidth,
                               onJump: model.onJump, onConnect: model.onConnect)
                .padding(.top, Self.topPadding)
                .frame(width: size.width, height: size.height, alignment: .top)
                .allowsHitTesting(peek == nil)
            if let peek, let line = PeekContent.make(for: peek, sessions: appState.store.ordered,
                                                     showsTaskText: appState.showsTaskText) {
                PeekLine(content: line, pillHeight: 22, compact: true,
                         leading: Self.peekLeading, trailing: Self.peekTrailing,
                         onJump: { jump(to: line.sessionID) }, onShow: model.onShow)
                    .frame(width: FloatingLayout.peekCapsule.width, height: FloatingLayout.peekCapsule.height)
                    .overlay(alignment: .bottom) {
                        PeekHairline(tone: line.tone, hold: model.peekHold, inset: FloatingLayout.peekRadius)
                            .allowsHitTesting(false)
                    }
                    .modifier(ContentReveal(visible: contentVisible))
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private var peekItem: PeekItem? {
        if case .peek(let item) = model.presentation { return item }
        return nil
    }

    private func jump(to id: String?) {
        guard let id, let session = appState.store.sessions[id] else { return }
        appState.jump(to: session)
        model.onJump()
    }

    private func apply(_ shape: PanelShape) {
        let target = CGRect(origin: .zero, size: shape.size)
        switch shape.change {
        case .none:
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { drawn = target }
        case .spring:
            withAnimation(Motion.open(reduced: reduced)) { drawn = target }
        case .grow(let from):
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { drawn = from }
            // The start has to be drawn once before the spring can leave it: set in
            // the same update, SwiftUI animates only from what was on screen.
            DispatchQueue.main.async {
                withAnimation(Motion.open(reduced: reduced)) { drawn = target }
                contentVisible = true
            }
        }
    }
}
