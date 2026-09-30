import SwiftUI
import CodeCatCore

/// What the floating cat's windows show and the numbers they are drawn with, shared
/// by `FloatingController`, which decides, and the views, which draw.
final class FloatingModel: ObservableObject {
    @Published var presentation: IslandPresentation = .compact
    @Published var peekHold: IslandPresenter.PeekHold?
    /// The list panel's height as placed (`FloatingLayout.panelPlacement`), and
    /// whether it opened above the cat.
    @Published var panelHeight: CGFloat = 0
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
/// capsule's right half (Figma 06 "At rest"). While the peek or the list is open the
/// capsule makes way for them and the cat stands on theirs.
@MainActor
struct FloatingCatView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var model: FloatingModel
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    var body: some View {
        let tone = appState.store.aggregate.tone
        ZStack(alignment: .topLeading) {
            if !model.presentation.isOpen {
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

/// The panel next to the cat: the list, in a 300 pt black panel with the rim (spec
/// §9). Task 9 adds the peek capsule to it. It fills its window, which the controller
/// sizes to the panel plus `FloatingLayout.margin` for the bloom.
struct FloatingPanelView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var model: FloatingModel
    /// The host's pointer: the cards' hover reads it (`onHoverRegion`), as on the island.
    let pointer: PointerTracker
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    /// Above the first card, and in all: 14 above, 10 below.
    static let topPadding: CGFloat = 14
    static let padding: CGFloat = 24

    var body: some View {
        let reduced = systemReduceMotion || Motion.reduceMotionForced
        let tone = appState.store.aggregate.tone
        let size = CGSize(width: FloatingLayout.panelWidth, height: model.panelHeight)
        ZStack(alignment: .top) {
            CapsuleSurface(size: size, radius: FloatingLayout.panelRadius, tone: tone,
                           bloom: RimLight.bloom(for: .expanded))
            // The list's own maximum is the room on screen, so it reports its natural
            // height (`listMaxHeight`); the scroll view never outgrows the panel.
            IslandExpandedView(appState: appState, visible: model.presentation == .expanded,
                               maxHeight: max(0, model.listMaxHeight - Self.padding),
                               width: FloatingLayout.panelWidth,
                               onJump: model.onJump, onConnect: model.onConnect)
                .padding(.top, Self.topPadding)
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipShape(RoundedRectangle(cornerRadius: FloatingLayout.panelRadius, style: .continuous))
        }
        .onPreferenceChange(IslandContentHeightKey.self) { model.onListHeight($0 + Self.padding) }
        .padding(FloatingLayout.margin)
        .environmentObject(pointer)
        .environment(\.islandReduceMotion, reduced)
        .environment(\.colorScheme, .dark)
    }
}
