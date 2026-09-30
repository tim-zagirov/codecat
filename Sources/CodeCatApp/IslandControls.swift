import SwiftUI
import CodeCatCore

/// A 22 pt pill button — the island's only button shape. `Open ↗` in a waiting tone
/// is the one coloured button on the island: it is the one that needs you (§5.4).
/// The peek's pill is 24 pt tall with 12 pt padding (Figma 03, decision 11): the peek
/// has one line, and a bigger target reads better at a glance.
struct PillButton: View {
    let title: String
    var fill: Color = IslandPalette.pill
    var textColor: Color = IslandPalette.primary
    var height: CGFloat = 22
    var horizontalPadding: CGFloat = 10
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(IslandPalette.numberFont)
                .foregroundStyle(textColor)
                .padding(.horizontal, horizontalPadding)
                .frame(height: height)
                .background(Capsule().fill(fill))
        }
        .buttonStyle(.plain)
        .pointingHandOnHover()
    }
}

/// The crashed card's ×: `SessionStore.dismiss(id:)`.
struct DismissButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(IslandPalette.secondary)
                .frame(width: 20, height: 20)
                .background(Circle().fill(IslandPalette.pill))
        }
        .buttonStyle(.plain)
        .help(L10n.t("card.dismiss", "Dismiss"))
        .pointingHandOnHover()
    }
}

/// "•••" in the open island's header: Settings (§5.3).
struct SettingsButton: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(IslandPalette.primary)
                .frame(width: IslandLayout.settingsButtonSize, height: IslandLayout.settingsButtonSize)
                .background(Circle().fill(hovered ? IslandPalette.pillHover : IslandPalette.pill))
        }
        .buttonStyle(.plain)
        .help(L10n.t("island.settings", "Settings"))
        .onHoverRegion { phase in
            if case .active = phase { hovered = true } else { hovered = false }
        }
        .pointingHandOnHover()
    }
}
