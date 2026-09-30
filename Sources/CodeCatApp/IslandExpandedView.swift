import SwiftUI
import CodeCatCore

/// The open island's content — spec §5.4: one card per session in the store's order
/// (waiting, crashed, working, done), idle sessions folded into one line at the end.
///
/// No background and no shape: `IslandView` draws those and clips this by the same
/// animated silhouette. The one thing reported outward is the height, capped at what
/// the screen allows (`IslandContentHeightKey`); beyond it the list scrolls.
struct IslandExpandedView: View {
    @ObservedObject var appState: AppState
    /// The content's fade (`ContentReveal`): false while the shape is still growing or
    /// already closing.
    let visible: Bool
    let maxHeight: CGFloat
    var onJump: () -> Void = {}
    var onConnect: () -> Void = {}

    @State private var idleUnfolded = false
    @Environment(\.islandReduceMotion) private var reduced

    var body: some View {
        let ordered = appState.store.ordered
        let active = ordered.filter { $0.status != .idle }
        let idle = ordered.filter { $0.status == .idle }
        let nameCounts = Dictionary(ordered.map { ($0.projectName, 1) }, uniquingKeysWith: +)
        // Keyed by section as well as order: from all idle to two working the store's
        // order of ids stayed the same, so a key of `ordered` alone did not see two
        // sessions leave the fold for cards, and nothing animated.
        let order = [active.map(\.id), idle.map(\.id)]
        let showsOnboarding = !appState.hooksInstalled && !appState.firstRunDismissed
        let footer = appState.powerFooter
        ScrollView {
            // With Reduce Motion nothing slides (§11): a change of order swaps the
            // whole list for a new one and the two cross-fade, the way the surface
            // swaps its outline. Without it the `id` is constant and the cards keep
            // their identity, so the one that moved slides and the others make room.
            ZStack(alignment: .top) {
                list(active: active, idle: idle, nameCounts: nameCounts,
                     showsOnboarding: showsOnboarding, footer: footer)
                    .id(reduced ? AnyHashable(order) : AnyHashable(0))
                    .transition(.opacity)
            }
            .animation(reduced ? Motion.reducedCrossfade : Motion.reposition, value: order)
            // Unfolding appends cards below the fold line, so nothing above them
            // moves: with Reduce Motion they only fade in.
            .animation(reduced ? Motion.reducedCrossfade : Motion.reposition, value: idleUnfolded)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: IslandContentHeightKey.self, value: min(proxy.size.height, maxHeight))
            })
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: IslandLayout.expandedWidth)
        .frame(maxHeight: maxHeight)
    }

    /// Every item carries its own `ContentReveal`, the unfolded idle cards too: the
    /// brief left them without one, so on close they would have stayed opaque while
    /// the rest faded out, and the closing shape would have cut through them.
    private func list(active: [Session], idle: [Session], nameCounts: [String: Int],
                      showsOnboarding: Bool, footer: PowerFooter) -> some View {
        let empty = active.isEmpty && idle.isEmpty
        return VStack(alignment: .leading, spacing: 6) {
            if showsOnboarding {
                OnboardingCard(appState: appState, onConnect: onConnect)
                    .modifier(ContentReveal(visible: visible, index: 0))
            } else if empty {
                EmptyIslandView()
                    .modifier(ContentReveal(visible: visible, index: 0))
            }
            ForEach(Array(active.enumerated()), id: \.element.id) { index, session in
                card(session, nameCounts)
                    .modifier(ContentReveal(visible: visible, index: index))
            }
            if !idle.isEmpty {
                IdleFoldRow(count: idle.count, unfolded: $idleUnfolded)
                    .modifier(ContentReveal(visible: visible, index: active.count))
                if idleUnfolded {
                    ForEach(Array(idle.enumerated()), id: \.element.id) { index, session in
                        card(session, nameCounts)
                            .modifier(ContentReveal(visible: visible, index: active.count + 1 + index))
                            .transition(.opacity)
                    }
                }
            }
            // §5.5: only when there is something to say, and never on an empty island.
            if !empty, !footer.isEmpty {
                PowerFooterView(footer: footer)
                    .modifier(ContentReveal(visible: visible, index: active.count + 1))
            }
        }
        .padding(.horizontal, 12)
    }

    private func card(_ session: Session, _ nameCounts: [String: Int]) -> some View {
        SessionCardView(appState: appState, session: session,
                        displayName: displayName(session, shared: (nameCounts[session.projectName] ?? 0) >= 2),
                        onJump: onJump)
    }

    /// S22: two cards with one project name are told apart by their tty.
    private func displayName(_ session: Session, shared: Bool) -> String {
        guard shared, let tty = session.tty, !tty.isEmpty else { return session.projectName }
        return "\(session.projectName) · \(tty)"
    }
}

/// Sessions open with nothing asked of them, folded into one line — spec §5.4. They
/// matter only as "still open"; three idle cards would push the waiting one down.
struct IdleFoldRow: View {
    let count: Int
    @Binding var unfolded: Bool
    @State private var hovered = false
    @Environment(\.islandReduceMotion) private var reduced

    var body: some View {
        Button { unfolded.toggle() } label: {
            HStack(spacing: 8) {
                Circle().fill(ToneColor.island(.sleeping)).frame(width: 6, height: 6)
                Text(L10n.f("card.idle.fold", "%d open without a task", count))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(IslandPalette.tertiary)
                Spacer(minLength: 8)
                // The `›` character, as spec and Figma write it: a `chevron.right`
                // symbol at 10 pt drew 5 × 8.5 pt against the design's 4 × 5.
                Text("›")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(IslandPalette.tertiary)
                    .rotationEffect(.degrees(unfolded ? 90 : 0))
                    // A turn is motion: with Reduce Motion the chevron points down at once.
                    .animation(reduced ? nil : Motion.reposition, value: unfolded)
            }
            .padding(.horizontal, 14)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(hovered ? IslandPalette.card : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHoverRegion { phase in
            if case .active = phase { hovered = true } else { hovered = false }
        }
        .pointingHandOnHover()
    }
}

/// The power state under the list (§5.5), 11 medium white 50 %.
struct PowerFooterView: View {
    let footer: PowerFooter

    var body: some View {
        HStack(spacing: 8) {
            if let text = footer.leftText {
                Image(systemName: "power").font(.system(size: 10, weight: .semibold))
                Text(text)
            }
            Spacer(minLength: 8)
            if footer.lidOn { Text(L10n.t("footer.lid", "Closed lid: on")) }
        }
        .font(IslandPalette.metaFont)
        .foregroundStyle(IslandPalette.footer)
        .lineLimit(1)
        .padding(.horizontal, 4)
        .padding(.top, 8)
    }
}

/// No sessions, hooks installed (§5.6): one line of help, no chrome, no light.
struct EmptyIslandView: View {
    var body: some View {
        // 5, not 6: the code token's 1 pt padding makes the second row 2 pt taller
        // than a line of text, and at 6 the body measured 127 pt against Figma's 126
        // with the line 1 pt lower than the frame's.
        VStack(spacing: 5) {
            Text(L10n.t("empty.title", "Agents are asleep"))
                .font(IslandPalette.nameFont)
                .foregroundStyle(IslandPalette.primary)
            HStack(spacing: 5) {
                Text(L10n.t("empty.start", "Start"))
                CodeToken("claude")
                Text(L10n.t("empty.end", "in a terminal and the cat wakes up."))
            }
            .font(IslandPalette.bodyFont)
            .foregroundStyle(IslandPalette.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }
}

/// Hooks not installed (§5.6): the whole onboarding is one card, and it asks before
/// it writes — **Connect…** runs the existing confirm flow, through the controller
/// (`IslandModel.onConnect`), which settles the pointer once the dialog is gone.
struct OnboardingCard: View {
    @ObservedObject var appState: AppState
    let onConnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("onboarding.title", "Connect Claude Code"))
                .font(IslandPalette.nameFont)
                .foregroundStyle(IslandPalette.primary)
            Text(L10n.t("onboarding.body",
                        "CodeCat adds five hook entries to ~/.claude/settings.json, so it knows the moment "
                        + "an agent needs you. It shows them first and touches nothing else."))
                .font(IslandPalette.bodyFont)
                .foregroundStyle(IslandPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                PillButton(title: L10n.t("onboarding.connect", "Connect…"), fill: .white, textColor: .black,
                           action: onConnect)
                PillButton(title: L10n.t("onboarding.later", "Not now")) {
                    appState.firstRunDismissed = true
                }
            }
            .padding(.top, 4)
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 16, trailing: 16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(IslandPalette.card))
    }
}

/// Height of the open list as the layout measured it, capped. Read by `IslandView`,
/// which grows the shape to it.
struct IslandContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
