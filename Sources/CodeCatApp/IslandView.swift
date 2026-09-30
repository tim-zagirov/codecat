import SwiftUI
import CodeCatCore

/// The island — spec §4, §5: one black shape around the notch that inhales under the
/// cursor, springs open into the list and closes back into the strip.
///
/// It fills the whole window, which `IslandController` sizes larger than the shape
/// (room to inhale, open and cast shadows), draws the shape centred at the top, and
/// lays the cat and the right wing out from the notch's centre — so neither moves
/// when the window changes size under them, and the cat stays exactly where it was
/// when the island opens (§5.3).
///
/// The drawn shape (`shown`) trails `model.presentation` on purpose: opening waits
/// until the list has been measured — a spring from zero to zero opens nothing — and
/// closing waits for the list to fade out first (§5.2, "content out").
struct IslandView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var model: IslandModel
    let pointer: PointerTracker
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    @State private var shown: IslandPresentation = .compact
    @State private var listHeight: CGFloat = 0
    /// The list is in the view tree from the moment the island starts opening until
    /// the close spring has settled.
    @State private var contentMounted = false
    /// Drives `ContentReveal`: false while the shape is still growing or already closing.
    @State private var contentVisible = false
    @State private var closing: Task<Void, Never>?

    private var reduced: Bool { systemReduceMotion || Motion.reduceMotionForced }
    private var metrics: IslandMetrics { model.metrics }
    private var tone: MascotTone { appState.store.aggregate.tone }

    private var expandedHeight: CGFloat {
        IslandLayout.expandedHeight(listHeight: listHeight, maxHeight: metrics.expandedMaxHeight)
    }
    /// Reduce Motion has no inhale (§11): the hovered island is drawn compact.
    private var drawn: IslandPresentation { reduced && shown == .inhaled ? .compact : shown }
    private var bodyShape: IslandBody {
        IslandLayout.body(for: drawn, compact: metrics.compactBody, expandedHeight: expandedHeight)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                surface
                if contentMounted { content(canvas: proxy.size) }
                header(canvasWidth: proxy.size.width)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .onChange(of: model.presentation) { old, new in presentationChanged(from: old, to: new) }
        .onPreferenceChange(IslandContentHeightKey.self) { listMeasured($0) }
        .onChange(of: expandedHeight, initial: true) { _, height in model.onExpandedHeight(height) }
        .environmentObject(pointer)
        .environment(\.islandReduceMotion, reduced)
        .environment(\.colorScheme, .dark)
    }

    /// With Reduce Motion a change of shape is a 0.2 s cross-fade between the old and
    /// the new outline (§11), not a spring: the `id` swaps the surface, the
    /// transition fades it.
    private var surface: some View {
        IslandSurface(bodyShape: bodyShape, tone: tone, presentation: drawn)
            .id(reduced ? AnyHashable(bodyShape) : AnyHashable(0))
            .transition(.opacity)
    }

    /// The open list, under the header band, clipped by the same animated shape.
    ///
    /// With Reduce Motion the clip takes the final shape at once: `IslandShape` is
    /// animatable, and inside `Motion.open(reduced:)`'s transaction the clip grew
    /// through intermediate sizes while the list was already half visible — a capture
    /// showed the rows cut off at ≈ 375 × 200 pt inside the full-size faded outline.
    /// Only the clip loses the animation: `ContentReveal` sets its own, so the list
    /// still cross-fades.
    private func content(canvas: CGSize) -> some View {
        let width = IslandLayout.expandedWidth
        return IslandExpandedView(appState: appState, visible: contentVisible,
                                  maxHeight: max(0, metrics.expandedMaxHeight - IslandLayout.headerHeight
                                                 - IslandLayout.listBottomPadding),
                                  onJump: model.onJump, onConnect: model.onConnect)
            .padding(.leading, (canvas.width - width) / 2)
            .padding(.top, IslandLayout.headerHeight)
            .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
            .clipShape(IslandShape(bodyShape: bodyShape))
            .transaction { if reduced { $0.animation = nil } }
    }

    /// The cat in the left wing and the live data in the right, both centred on their
    /// wings, measured from the notch's centre, and on the notch's band rather than
    /// the strip, which runs a rim's width lower.
    private func header(canvasWidth: CGFloat) -> some View {
        let centre = canvasWidth / 2
        let side = metrics.notchWidth / 2 + metrics.wingWidth / 2
        let y = metrics.bandHeight / 2
        return ZStack(alignment: .topLeading) {
            MascotView(skin: appState.skin,
                       status: appState.store.aggregate,
                       indicator: appState.store.indicator,
                       drawingSize: metrics.spriteSize,
                       canvasSize: CGSize(width: metrics.spriteSize.width, height: metrics.bandHeight),
                       showsBadge: false,
                       since: appState.statusSince,
                       onLoadFailure: { [appState] skin in appState.reportSkinLoadFailure(skin) })
                .frame(width: metrics.wingWidth, height: metrics.bandHeight)
                .position(x: centre - side, y: y)
                .allowsHitTesting(false)
            IslandWingView(content: RightWing.content(for: appState.store.ordered, aggregate: tone, now: Date()))
                .frame(width: metrics.wingWidth, height: metrics.bandHeight)
                // Open, the wing's live data gives way to the header's dots (§5.3).
                .opacity(contentVisible ? 0 : 1)
                .animation(Motion.contentOut, value: contentVisible)
                .position(x: centre + side, y: y)
                .allowsHitTesting(false)
            if contentMounted {
                // The dots form of the wing (`RightWing.header`, kept clear of the
                // notch) and Settings, 20 pt in from the body's right edge (Figma 04,
                // "Header right").
                HStack(spacing: IslandLayout.headerButtonSpacing) {
                    IslandWingView(content: RightWing.header(
                        for: appState.store.ordered, aggregate: tone,
                        room: IslandLayout.headerDotsRoom(notchWidth: metrics.notchWidth)))
                    SettingsButton(action: model.onSettings)
                }
                .frame(width: IslandLayout.expandedWidth - 2 * IslandLayout.headerTrailingInset,
                       height: metrics.bandHeight, alignment: .trailing)
                .modifier(ContentReveal(visible: contentVisible))
                .position(x: centre, y: y)
            }
        }
    }

    // MARK: - Sequencing

    private func presentationChanged(from old: IslandPresentation, to new: IslandPresentation) {
        closing?.cancel()
        closing = nil
        switch (old.isOpen, new.isOpen) {
        case (false, true):
            contentMounted = true
            // The height is known from the last time the list was open; otherwise it
            // arrives with the first layout pass (`listMeasured`).
            if listHeight > 0 { beginOpen() }
        case (true, false):
            contentVisible = false
            closing = Task { @MainActor in
                try? await Task.sleep(for: .seconds(Motion.contentOutDuration))
                guard !Task.isCancelled else { return }
                withAnimation(Motion.close(reduced: reduced)) { shown = new }
                try? await Task.sleep(for: .seconds(Motion.closeSpringSettle))
                guard !Task.isCancelled else { return }
                contentMounted = false
            }
        default:
            // Compact ↔ inhaled. A close interrupted by the cursor coming back takes
            // the list down at once: invisible rows must not answer hover.
            if !new.isOpen {
                contentVisible = false
                contentMounted = false
            }
            withAnimation(reduced ? nil : Motion.hoverInhale) { shown = new }
        }
    }

    private func beginOpen() {
        withAnimation(Motion.open(reduced: reduced)) { shown = model.presentation }
        contentVisible = true
    }

    private func listMeasured(_ height: CGFloat) {
        guard height > 0 else { return }
        if shown.isOpen {
            withAnimation(reduced ? nil : Motion.reposition) { listHeight = height }
        } else {
            listHeight = height
            if model.presentation.isOpen, contentMounted { beginOpen() }
        }
    }
}
