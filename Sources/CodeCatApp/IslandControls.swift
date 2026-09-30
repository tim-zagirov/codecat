import SwiftUI
import CodeCatCore

/// A 22 pt pill button — the island's only button shape. `Open ↗` in a waiting tone
/// is the one coloured button on the island: it is the one that needs you (§5.4).
struct PillButton: View {
    let title: String
    var fill: Color = IslandPalette.pill
    var textColor: Color = IslandPalette.primary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(IslandPalette.numberFont)
                .foregroundStyle(textColor)
                .padding(.horizontal, 10)
                .frame(height: 22)
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
