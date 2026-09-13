import SwiftUI
import CodeCatCore

/// The floating mode's panel. All of its content moved to `SessionListView` and
/// `SettingsSectionView`; what is left here is the heading, the background and the
/// size — the things that distinguish this panel from the island menu.
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
        VStack(alignment: .leading, spacing: 10) {
            title
            SessionListView(appState: appState, onJump: onJump)
            Divider()
            SettingsSectionView(appState: appState)
        }
        .font(.system(size: 12))
        .padding(14)
        .frame(width: 290, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .environmentObject(pointer)
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

    /// The R1 colour vocabulary, as its own local copy — the same pattern
    /// `IslandView` and `MascotBadge` each follow. The four active tones match those
    /// surfaces byte for byte; only `.sleeping` differs, because this panel sits on a
    /// light system material where their `white@0.35` would be invisible — `.secondary`
    /// is the material-aware muted grey that reads on it.
    private func color(for tone: MascotTone) -> Color {
        switch tone {
        case .working: return .green
        case .waiting: return .orange
        case .done: return .blue
        case .problem: return .red
        case .sleeping: return .secondary
        }
    }
}
