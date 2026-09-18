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
    /// Whether the tone glow's bloom has finished, so its `TimelineView` can stop
    /// ticking. Deliberately `@State`, not a value computed at render time: SwiftUI
    /// only notices a new `paused` argument when the view's body runs again, and
    /// `IslandView.body` only runs on `appState.objectWillChange` — session activity,
    /// or otherwise every 15 s from the maintenance timer. A `let` computed inline
    /// would sit `paused: false` at 60 fps for however long it took the next
    /// incidental re-render to notice the bloom was over. `@State` survives the
    /// controller's `hosting.rootView = …` reassignment exactly as `menuHeight` and
    /// `revealed` already do, so driving the pause from it is safe.
    @State private var bloomSettled = false
    /// The glow's own bloom origin and colour — not `appState.statusSince`, which
    /// resets on every `AggregateStatusKey` change (it follows `aggregate`, the
    /// whole-fleet rollup) while the glow paints `indicator.tone`. Two working
    /// sessions plus one crashing flips `aggregate` to `.problem`, resetting
    /// `statusSince`, while `indicator` stays `.working`: keyed to `statusSince` the
    /// green glow would snap to zero and rebloom for a tone that never changed.
    /// `glowTone` is set from `indicator.tone` only when that tone actually changes,
    /// so the pair tracks the glow's own transitions instead.
    @State private var glowSince = Date()
    @State private var glowTone: MascotTone = .sleeping

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
                               width: bodyWidth, maxContentHeight: maxContentHeight,
                               onJump: onJump)
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
        .environmentObject(pointer)
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
                   indicator: appState.store.indicator,
                   drawingSize: spriteSize,
                   canvasSize: CGSize(width: spriteSize.width, height: height),
                   showsBadge: false,
                   since: appState.statusSince,
                   onLoadFailure: { [appState] skin in appState.reportSkinLoadFailure(skin) })
            .background(glow)
    }

    /// A soft radial wash behind the cat in the aggregate tone — the state readable
    /// from across the room, before the eye finds the dots. Sleeping draws nothing.
    ///
    /// The bloom's progress is computed from `glowSince`, not from view state: the
    /// controller reassigns the island's root view on every state change, and a
    /// `@State` progress value would replay the bloom on each of those. But *whether
    /// the timer keeps ticking* has to be `@State` (`bloomSettled`): the pause has to
    /// flip the instant the bloom is over, not whenever the view next happens to be
    /// re-evaluated — see the doc comment on `bloomSettled`.
    private var glow: some View {
        let tone = appState.store.indicator.tone
        return TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: bloomSettled)) { context in
            let progress = reduceMotion ? 1.0
                : Motion.easeOut(context.date.timeIntervalSince(glowSince) / Motion.bloomDuration)
            Circle()
                .fill(RadialGradient(colors: [ToneColor.color(for: glowTone).opacity(0.42), .clear],
                                     center: .center, startRadius: 0, endRadius: height))
                .frame(width: height * 2, height: height * 2)
                .scaleEffect(0.9 + 0.1 * progress)
                .opacity(glowTone == .sleeping ? 0 : progress)
                .animation(Motion.toneCrossfade, value: glowTone)
        }
        .allowsHitTesting(false)
        // First appearance only: once `glowTone` has been set to anything real, later
        // `onAppear`s from the controller's view-reassignment must not touch it —
        // that is what `.onChange(of: tone)` below is for.
        .onAppear {
            guard glowTone == .sleeping else { return }
            glowTone = tone
            glowSince = Date()
            bloomSettled = false
        }
        // The indicator's own tone changed — not the aggregate's — so this is the one
        // place the glow's bloom restarts.
        .onChange(of: tone) { _, newTone in
            glowTone = newTone
            glowSince = Date()
            bloomSettled = false
        }
        // Cancelled and restarted whenever `glowSince` changes. Sleeps for the rest of
        // the bloom and then pauses the timer; on first appearance, when the tone has
        // already been settled for a while, the remaining time is zero or negative and
        // this sets `bloomSettled` on the next run loop turn without ever sleeping.
        .task(id: glowSince) {
            let remaining = Motion.bloomDuration + 0.05 - Date().timeIntervalSince(glowSince)
            if remaining > 0 {
                try? await Task.sleep(for: .seconds(remaining))
            }
            // A second tone change within one bloom window cancels this task and starts
            // a new one for the new `glowSince`; `Task.sleep` then throws and `try?`
            // above swallows it. Without this guard the cancelled task would fall
            // straight through to `bloomSettled = true`, racing the new task's own
            // reset above and freezing the glow mid-bloom for the tone that replaced
            // it.
            guard !Task.isCancelled else { return }
            bloomSettled = true
        }
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
        // The one source both surfaces read (see `SessionStore.indicator`), so the
        // island counter and the floating badge can never disagree about a state.
        let indicator = appState.store.indicator
        if indicator.tone == .sleeping {
            // Nothing to count — but the island stays put, or there would be nothing to
            // hover. A dot without the capsule: an empty shape earns nothing.
            Circle()
                .fill(color(for: .sleeping))
                .frame(width: 6, height: 6)
        } else {
            let dots = appState.store.dots
            if (1...4).contains(dots.count) {
                // One dot per session reads state and count at once; the capsule below
                // collapses both into a single tone and a number.
                cluster(dots)
            } else if indicator.tone == .waiting {
                // Waiting is the one state that pulses — the same device the badge uses,
                // and now the same calm 3 s cycle (C6) — because it is the one asking for
                // the user's input. Nothing else pulses.
                capsule(for: indicator)
                    .phaseAnimator([false, true]) { content, pulse in
                        content.scaleEffect(pulse ? 1.08 : 1.0)
                    } animation: { _ in Motion.pulse }
            } else {
                // Problem/done are now visible too: the capsule shows for every non-sleeping
                // tone, so a crashed session is no longer an invisible grey dot.
                capsule(for: indicator)
            }
        }
    }

    /// One dot per session, up to four: one centred, two side by side, three or four
    /// in a 2×2 grid (§`xOffset`/`yOffset`). Each dot is its session's own tone, so
    /// "two working and one waiting" is legible without opening the menu — the
    /// capsule's one tone and one count could not say it. Five or more fall back to
    /// the capsule: a cluster of nine dots is a rash, not a reading.
    ///
    /// A single `ZStack` positioned by offset, not rows of an `HStack`/`VStack`: the
    /// `ForEach` is keyed by `SessionDot.id`, so when a session's tone changes it is
    /// the *same* dot that recolours and slides to its new slot, rather than a row
    /// layout reshuffling and crossfading whichever dot lands at the old offset.
    private func cluster(_ dots: [SessionDot]) -> some View {
        ZStack {
            ForEach(dots) { sessionDot in
                let index = dots.firstIndex(where: { $0.id == sessionDot.id }) ?? 0
                dotView(sessionDot.tone)
                    .offset(x: xOffset(index, dots.count), y: yOffset(index, dots.count))
            }
        }
        .frame(width: 16, height: 16)
        .animation(reduceMotion ? nil : Motion.reposition, value: dots)
        .help(clusterHelp(dots.map(\.tone)))
    }

    /// The horizontal slot for dot `index` of `count`: centred for one, else the
    /// same left/right split (±5 pt, a 10 pt pitch for 6 pt dots and a 4 pt gap)
    /// whether the row holds two dots or is the top/bottom of a 2×2 grid.
    private func xOffset(_ index: Int, _ count: Int) -> CGFloat {
        guard count >= 2 else { return 0 }
        return index % 2 == 0 ? -5 : 5
    }

    /// The vertical slot for dot `index` of `count`: one or two dots sit on a single
    /// centred row; three or four split into a top row (indices 0, 1) and a bottom
    /// row (indices 2, 3).
    private func yOffset(_ index: Int, _ count: Int) -> CGFloat {
        guard count >= 3 else { return 0 }
        return index < 2 ? -5 : 5
    }

    private func dotView(_ tone: MascotTone) -> some View {
        let base = Circle()
            .fill(ToneColor.color(for: tone))
            .frame(width: 6, height: 6)
            .animation(Motion.toneCrossfade, value: tone)
            .transition(reduceMotion ? .opacity
                        : .scale(scale: 0.6).combined(with: .opacity))
        return Group {
            if tone == .waiting {
                if reduceMotion {
                    // No movement, but the signal survives: a ring makes the waiting
                    // dot the one that is not like the others.
                    base.overlay(Circle().strokeBorder(ToneColor.color(for: .waiting), lineWidth: 1.5)
                                    .frame(width: 11, height: 11))
                } else {
                    base.phaseAnimator([false, true]) { content, pulse in
                        content.scaleEffect(pulse ? 1.35 : 1.0)
                    } animation: { _ in Motion.pulse }
                }
            } else {
                base
            }
        }
    }

    /// "2 working, 1 waiting for you" — the same words the menu-bar tooltip uses.
    private func clusterHelp(_ dots: [MascotTone]) -> String {
        var parts: [String] = []
        let working = dots.filter { $0 == .working }.count
        let waiting = dots.filter { $0 == .waiting }.count
        if working > 0 { parts.append(L10n.f("menubar.working", "working: %d", working)) }
        if waiting > 0 { parts.append(L10n.f("menubar.waiting", "waiting: %d", waiting)) }
        if dots.contains(.problem) { parts.append(L10n.t("menubar.problem", "problem")) }
        if dots.contains(.done) { parts.append(L10n.t("menubar.done", "done")) }
        return parts.joined(separator: ", ")
    }

    /// The counter capsule: the state dot, the count when there is one, and — when a
    /// session has crashed alongside live work — a second red dot trailing it, so a
    /// dead session never blanks the number for the ones still running.
    private func capsule(for indicator: MascotIndicator) -> some View {
        HStack(spacing: 4) {
            statusDot(tone: indicator.tone)
            if indicator.count > 0 {
                // The digit is always white: the dot carries the state. A red digit next
                // to a red dot is two signals for one thing.
                Text("\(indicator.count)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .monospacedDigit()
            }
            if indicator.crashedMarker {
                Circle()
                    .fill(color(for: .problem))
                    .frame(width: 5, height: 5)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Capsule().fill(Color.white.opacity(0.10)))
    }

    /// The dot's colour repeats the status colours in the session list exactly: a dot
    /// on the island and a dot in a menu row have to mean the same thing, or the colour
    /// system falls apart into two.
    private func statusDot(tone: MascotTone) -> some View {
        Circle()
            .fill(color(for: tone))
            .frame(width: 6, height: 6)
    }

    /// The R1 colour vocabulary — the same literals the session row dots and the
    /// floating badge use, so all three surfaces are byte-identical.
    private func color(for tone: MascotTone) -> Color {
        ToneColor.color(for: tone)
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
