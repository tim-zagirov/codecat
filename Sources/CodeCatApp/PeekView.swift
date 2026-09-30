import SwiftUI
import CodeCatCore

/// The peek under the island's band — spec §6.2: the project and why, a pill on the
/// right, and a hairline in the tone that runs out with the hold. Laid out in the
/// 420 × 42 pt under the 36 pt header band: the line is centred on the peek's y 54
/// (Figma 03: 22 pt in from the body's left, the pill 20 pt in from its right).
struct PeekView: View {
    let content: PeekContent
    let hold: IslandPresenter.PeekHold?
    var onJump: () -> Void = {}
    var onShow: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            PeekLine(content: content, leading: 22, trailing: IslandLayout.headerTrailingInset,
                     onJump: onJump, onShow: onShow)
                .frame(height: 36)
            Spacer(minLength: 0)
            PeekHairline(tone: content.tone, hold: hold, inset: IslandLayout.expandedCornerRadius)
        }
        .frame(width: IslandLayout.expandedWidth, height: IslandLayout.peekHeight - IslandLayout.headerHeight)
    }
}

/// The peek's one line — the title, the reason and the pill — shared by the island's
/// peek and the floating cat's peek capsule (spec §9: "the same line"). It fills the
/// space it is given, so the whole of it, the insets too, takes the tap.
struct PeekLine: View {
    let content: PeekContent
    /// Figma 03's 24 pt on the island; the floating capsule's 44 pt holds the cards'
    /// 22 pt (Figma 06 "Peek").
    var pillHeight: CGFloat = 24
    /// The floating capsule's line (Figma 06 "Peek"): the cards' pill padding, at
    /// least 12 pt before the pill instead of 24, and the command as a word of the
    /// reason (`ReasonLineView.codeAsText`). Measured, `codecat wants to run npm
    /// test` and Open ↗ then take 267 pt of the 272 inside the capsule; with a
    /// 17 pt minimum (Figma's gap) they took 273 and the command lost its last
    /// letters. The reason is what is cut when the line is longer.
    var compact = false
    var leading: CGFloat = 0
    var trailing: CGFloat = 0
    var onJump: () -> Void = {}
    var onShow: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            Text(content.title)
                .font(IslandPalette.peekTitleFont)
                .foregroundStyle(IslandPalette.primary)
                .lineLimit(1)
                // In the capsule the reason gives way first: the project is who
                // asks, and a pill cut to "Ope…" is no button (captured).
                .layoutPriority(compact ? 2 : 0)
            ReasonLineView(segments: content.segments, codeAsText: compact)
            Spacer(minLength: compact ? 0 : 12)
            if compact { pill.fixedSize() } else { pill }
        }
        .padding(.leading, leading)
        .padding(.trailing, trailing)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        // The line itself: to the session, or to the list when the peek names
        // several. The pill and the chip are buttons of their own and win.
        .onTapGesture { content.sessionID == nil ? onShow() : onJump() }
        .pointingHandOnHover()
    }

    private var pillPadding: CGFloat { compact ? 10 : 12 }

    @ViewBuilder
    private var pill: some View {
        switch content.pill {
        case .open(let prominent):
            PillButton(title: L10n.t("card.open", "Open") + "\u{2002}↗",
                       fill: prominent ? ToneColor.island(.waiting) : IslandPalette.pill,
                       textColor: prominent ? .black : IslandPalette.primary,
                       height: pillHeight, horizontalPadding: pillPadding, action: onJump)
        case .chip(let link):
            HandoffChipView(link: link, index: 0)
        case .show:
            PillButton(title: L10n.t("peek.show", "Show"), height: pillHeight, horizontalPadding: pillPadding,
                       action: onShow)
        case .absent:
            EmptyView()
        }
    }
}

/// 1.5 pt in the tone, 6 pt above the bottom and between the bottom corners
/// (`inset`), shrinking with the time left; it stands still while the cursor holds
/// the peek.
struct PeekHairline: View {
    let tone: MascotTone
    let hold: IslandPresenter.PeekHold?
    let inset: CGFloat

    var body: some View {
        TimelineView(.animation(paused: !isRunning)) { context in
            GeometryReader { proxy in
                Capsule()
                    .fill(ToneColor.island(tone))
                    .frame(width: proxy.size.width * fraction(at: context.date))
            }
        }
        .frame(height: 1.5)
        .padding(.horizontal, inset)
        .padding(.bottom, 6)
    }

    private var isRunning: Bool {
        if case .running = hold { return true }
        return false
    }

    private func fraction(at date: Date) -> CGFloat {
        switch hold {
        case .running(let end, let total): return CGFloat(max(0, min(1, end.timeIntervalSince(date) / total)))
        case .paused(let remaining, let total): return CGFloat(max(0, min(1, remaining / total)))
        case nil: return 0
        }
    }
}
