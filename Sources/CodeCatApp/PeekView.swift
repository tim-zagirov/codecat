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
            HStack(spacing: 6) {
                Text(content.title)
                    .font(IslandPalette.peekTitleFont)
                    .foregroundStyle(IslandPalette.primary)
                    .lineLimit(1)
                ReasonLineView(segments: content.segments)
                Spacer(minLength: 12)
                pill
            }
            .padding(.leading, 22)
            .padding(.trailing, IslandLayout.headerTrailingInset)
            .frame(height: 36)
            .contentShape(Rectangle())
            // The line itself: to the session, or to the list when the peek names
            // several. The pill and the chip are buttons of their own and win.
            .onTapGesture { content.sessionID == nil ? onShow() : onJump() }
            .pointingHandOnHover()
            Spacer(minLength: 0)
            hairline
        }
        .frame(width: IslandLayout.expandedWidth, height: IslandLayout.peekHeight - IslandLayout.headerHeight)
    }

    @ViewBuilder
    private var pill: some View {
        switch content.pill {
        case .open(let prominent):
            PillButton(title: L10n.t("card.open", "Open") + "\u{2002}↗",
                       fill: prominent ? ToneColor.island(.waiting) : IslandPalette.pill,
                       textColor: prominent ? .black : IslandPalette.primary,
                       height: 24, horizontalPadding: 12, action: onJump)
        case .chip(let link):
            HandoffChipView(link: link, index: 0, large: true)
        case .show:
            PillButton(title: L10n.t("peek.show", "Show"), height: 24, horizontalPadding: 12, action: onShow)
        case .absent:
            EmptyView()
        }
    }

    /// 1.5 pt in the tone, between the bottom corners, shrinking with the time left;
    /// it stands still while the cursor holds the peek.
    private var hairline: some View {
        TimelineView(.animation(paused: !isRunning)) { context in
            GeometryReader { proxy in
                Capsule()
                    .fill(ToneColor.island(content.tone))
                    .frame(width: proxy.size.width * fraction(at: context.date))
            }
        }
        .frame(height: 1.5)
        .padding(.horizontal, IslandLayout.expandedCornerRadius)
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
