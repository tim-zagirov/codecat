import SwiftUI
import AppKit
import CodeCatCore

/// One session in the open island — spec §5.4. A card rather than a row: white 6 %
/// on black, 12 pt corners concentric with the island's 24 (12 pt in from its side),
/// a 16 pt column for the indicator and everything else in the text column. The
/// text depends on the status, in the order the user needs it: what a waiting
/// session wants, what a working one is doing, what a finished one handed back.
///
/// A click anywhere on a routable card jumps to its session; the pill, the chips and
/// the × are buttons of their own and win over that tap. A card with no route is
/// drawn at half opacity and says why — always, not on hover: a dimmed card with no
/// reason reads as broken.
struct SessionCardView: View {
    @ObservedObject var appState: AppState
    let session: Session
    /// The project name as the list shows it: with the tty when two cards share it (S22).
    let displayName: String
    var onJump: () -> Void = {}

    @State private var hovered = false

    var body: some View {
        let route = appState.route(for: session)
        let unavailable: UnavailableReason? = {
            if case .unavailable(let reason) = route { return reason }
            return nil
        }()
        let routable = unavailable == nil
        let card = HStack(alignment: .top, spacing: 10) {
            indicator
                .frame(width: 16, height: 16)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                head(showsArrow: routable && hovered)
                detail(routable: routable)
                if let unavailable {
                    // 11 regular, as Figma sets it: at 11 medium the longer English hint
                    // is 347 pt against a 346 pt column and lost its last word, and a
                    // cut reason reads as broken as none. Two lines if a translation
                    // still needs them.
                    Text(JumpMessages.rowHint(for: unavailable))
                        .font(.system(size: 11))
                        .foregroundStyle(IslandPalette.tertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(EdgeInsets(top: 11, leading: 12, bottom: 12, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(routable && hovered ? IslandPalette.cardHover : IslandPalette.card))
        .opacity(routable ? 1 : 0.5)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHoverRegion { phase in
            if case .active = phase {
                if !hovered { hovered = true }
            } else {
                hovered = false
            }
        }
        .onDisappear { hovered = false }

        if routable {
            card
                .onTapGesture { jump() }
                .pointingHandOnHover()
        } else {
            card
        }
    }

    /// Centred in an 18 pt row, as Figma lays it out: first-baseline alignment put the
    /// time 2 pt lower than the design, and SwiftUI's own line for a 15 pt name is a
    /// point taller than Figma's, which pushed every line under it down.
    private func head(showsArrow: Bool) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(displayName)
                .font(IslandPalette.nameFont)
                .foregroundStyle(IslandPalette.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(SessionTime.text(for: session))
                .font(IslandPalette.metaFont)
                .foregroundStyle(IslandPalette.tertiary)
                .monospacedDigit()
            if showsArrow {
                Text("↗")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.8))
            }
        }
        .frame(height: 18)
    }

    @ViewBuilder
    private func detail(routable: Bool) -> some View {
        switch session.status {
        case .working:
            if let task { line(task) }
            if showsText, let step = session.currentStep, let progress = session.stepProgress {
                CardStepLine(title: step.displayTitle, done: progress.done, total: progress.total)
                    .padding(.top, 2)
            }
        case .waitingForYou:
            // With the switch off the command stays private too: it can say as much
            // as the task does.
            ReasonLineView(segments: showsText ? PeekReason.segments(for: session) : [.text(session.status.title)])
            if routable {
                // An en space before the arrow: with a plain one the arrow sat 3 pt
                // closer to the word than in Figma and the pill was 64 pt, not 68.
                PillButton(title: L10n.t("card.open", "Open") + "\u{2002}↗",
                           fill: ToneColor.island(.waiting), textColor: .black, action: jump)
                    .padding(.top, 4)
            }
        case .done:
            line(showsText ? (session.handoff?.summary ?? doneText) : doneText)
            if showsText, let links = session.handoff?.links, !links.isEmpty {
                ChipFlow(spacing: 6) {
                    ForEach(Array(links.enumerated()), id: \.element.id) { index, link in
                        HandoffChipView(link: link, index: index)
                    }
                }
                .padding(.top, 4)
                // A chip's click must not also reach the card's tap (which jumps and
                // closes the island): SwiftUI resolves a `Button` before an ancestor's
                // `onTapGesture` on macOS, and an empty tap here still wins any tie
                // closer to the chips than the card's.
                .onTapGesture {}
            }
        case .crashed:
            HStack(spacing: 8) {
                ReasonLineView(segments: PeekReason.segments(for: session))
                Spacer(minLength: 8)
                DismissButton { appState.dismiss(session) }
            }
        case .idle:
            line(task ?? session.activityDescription)
        }
    }

    @ViewBuilder
    private var indicator: some View {
        switch session.status {
        case .working:
            if let progress = session.stepProgress {
                ProgressRing(done: progress.done, total: progress.total, tone: .working)
            } else {
                SessionDotView(tone: .working)
            }
        case .done:
            CheckDisc(tone: .done)
        case .idle:
            SessionDotView(tone: .sleeping)
        case .waitingForYou, .crashed:
            SessionDotView(tone: session.status.tone)
        }
    }

    private var showsText: Bool { appState.showsTaskText }

    private var task: String? {
        guard showsText, let text = session.taskText, !text.isEmpty else { return nil }
        return text
    }

    private var doneText: String { L10n.t("activity.done", "finished the task") }

    private func line(_ text: String) -> some View {
        Text(text)
            .font(IslandPalette.bodyFont)
            .foregroundStyle(IslandPalette.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// The hover is cleared first: the island closes on the jump, and no further
    /// hover event will arrive to clear it.
    private func jump() {
        hovered = false
        appState.jump(to: session)
        onJump()
    }
}

/// The step a working session is on: its title, `2/5` in the tone, and a 3 pt bar.
/// The title changes through a blur-fade (`AnyTransition.blurFade`).
struct CardStepLine: View {
    let title: String
    let done: Int
    let total: Int
    @Environment(\.islandReduceMotion) private var reduced

    var body: some View {
        // Figma's step block: a 14 pt row, 5 pt, the 3 pt bar. SwiftUI's line for 12 pt
        // is 15, and with the brief's 7 pt gap the working card came out 3 pt taller
        // than the design.
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ZStack(alignment: .leading) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.8))
                        .lineLimit(1)
                        .id(title)
                        .transition(reduced ? .opacity : .blurFade)
                }
                .animation(Motion.stepTitle, value: title)
                Spacer(minLength: 8)
                Text(L10n.f("row.step.progress", "%d/%d", done, total))
                    .font(IslandPalette.numberFont)
                    .foregroundStyle(ToneColor.island(.working))
                    .monospacedDigit()
                    // Reduce Motion: the digits change in place instead of rolling (§11).
                    .contentTransition(reduced ? .identity : .numericText())
                    .animation(Motion.stepTitle, value: done)
            }
            .frame(height: 14)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(IslandPalette.barTrack)
                    Capsule()
                        .fill(ToneColor.island(.working))
                        .frame(width: proxy.size.width * CGFloat(min(done, total)) / CGFloat(max(total, 1)))
                }
            }
            .frame(height: 3)
            .animation(reduced ? nil : Motion.reposition, value: [done, total])
        }
    }
}
