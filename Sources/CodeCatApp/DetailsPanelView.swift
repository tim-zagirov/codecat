import AppKit
import SwiftUI
import CodeCatCore

/// The floating mode's panel. Skins and settings moved to the Settings window
/// (Task 4); what is left here is the title, the session list, the background and
/// the size — the things that distinguish this panel from an ordinary window.
struct DetailsPanelView: View {
    @ObservedObject var appState: AppState

    /// Called after a jump is started, so the panel can close itself: the user asked
    /// to be somewhere else.
    var onJump: () -> Void = {}

    /// See `PointerTracker`: the panel is key and SwiftUI's hover would work here,
    /// but the island's menu shares every row and tile with this panel, and one
    /// hover mechanism for both is the only way to keep them identical.
    let pointer: PointerTracker

    var body: some View {
        // The panel is positioned by `OverlayController`, which clamps its origin into
        // the visible frame and grows it to `fittingSize`. Left unbounded, an expanded
        // credits list makes the content taller than the screen; the clamp then pushes
        // the origin up until the title runs off the top edge. Capping the content's
        // height and scrolling the overflow keeps the title anchored where it opened —
        // the list scrolls inside the fixed frame instead of shoving the heading away.
        // `fittingSize` reports at most `maxHeight`, so the panel never grows past it.
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                title
                SessionListView(appState: appState, onJump: onJump)
            }
            .padding(14)
            .frame(width: 290, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 290)
        .frame(maxHeight: maxHeight)
        .font(.system(size: 12))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .environmentObject(pointer)
    }

    /// The tallest the panel's content may become before it scrolls: the main screen's
    /// visible height less a margin, so a full screen of sessions plus expanded credits
    /// stays on screen instead of running off the top. Falls back to a generous
    /// constant if no screen reports a size (never expected in practice).
    private var maxHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 800) - 40
    }

    /// The panel's title states the aggregate rather than the app's name: the same
    /// population the mascot's badge and the island counter show, so the first line
    /// answers "what is going on right now" instead of repeating "CodeCat". A leading
    /// dot in the tone colour carries the state; the text spells it out.
    private var title: some View {
        let indicator = appState.store.indicator
        return HStack(spacing: 6) {
            Circle().fill(color(for: indicator.tone)).frame(width: 8, height: 8)
            Text(titleText(indicator)).font(.headline)
        }
    }

    private func titleText(_ indicator: MascotIndicator) -> String {
        switch indicator.tone {
        case .working: return L10n.f("panel.title.working", "%d working", indicator.count)
        case .waiting: return L10n.f("panel.title.waiting", "%d waiting for you", indicator.count)
        case .problem: return L10n.t("panel.title.problem", "a session ended")
        case .done: return L10n.t("panel.title.done", "all done")
        case .sleeping: return L10n.t("panel.title.sleeping", "nothing running")
        }
    }

    /// The four active tones read from `ToneColor`, byte for byte identical to
    /// `IslandView` and `MascotBadge`; only `.sleeping` differs, because this panel
    /// sits on a light system material where `ToneColor`'s `white@0.35` would be
    /// invisible — `.secondary` is the material-aware muted grey that reads on it.
    private func color(for tone: MascotTone) -> Color {
        switch tone {
        case .sleeping: return .secondary
        default: return ToneColor.color(for: tone)
        }
    }
}
