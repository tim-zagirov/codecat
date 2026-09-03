import SwiftUI
import AppKit
import CodeCatCore

/// Skins and toggles. Split out of `DetailsPanelView` for the island menu, where
/// they are shown on a black background and only at the full level.
///
/// Everything here is computed straight from `appState` while `body` runs, so it
/// reflects live state on its own — no separate subscription to `store`/`awayLog`
/// is needed.
struct SettingsSectionView: View {
    @ObservedObject var appState: AppState

    /// A notched display is one `IslandLayout.notchRect` can actually be built for,
    /// not one that merely has a non-zero safe-area inset (see
    /// `IslandController.geometry()`): the same test for "there is a notch" has to be
    /// used both where the island really appears and here, where the user is warned
    /// about it in advance.
    private static var hasScreenWithNotch: Bool {
        NSScreen.screens.contains { screen in
            IslandLayout.notchRect(auxLeft: screen.auxiliaryTopLeftArea,
                                   auxRight: screen.auxiliaryTopRightArea) != nil
        }
    }

    @Environment(\.menuStyle) private var style

    var body: some View {
        VStack(alignment: .leading, spacing: style.blockSpacing) {
            sectionTitle(L10n.t("settings.view", "View"))
            Picker(L10n.t("settings.view", "View"), selection: $appState.displayMode) {
                ForEach(MascotDisplayMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if appState.displayMode == .island, !Self.hasScreenWithNotch {
                Text(L10n.t("settings.no.notch",
                            "This display has no notch, so the island won't appear."))
                    .font(.system(size: 10))
                    .foregroundStyle(style.tertiary)
            }

            // The toggle works in both modes — for the island and for the floating cat.
            // The menu bar carries a duplicate of it, and that duplicate is mandatory:
            // turn this on here while there are no sessions and the mascot disappears
            // along with this very menu, leaving nowhere to turn it off.
            SettingToggle(L10n.t("setting.hide.when.idle", "Hide the cat when nothing is running"),
                          isOn: $appState.hidesWhenNoSessions)

            MenuSeparator()
            // `SkinPickerView` draws the "Skin" heading itself — it owns it.
            SkinPickerView(appState: appState)

            MenuSeparator()
            // The panel never had a "Settings" heading, and adding one here would mean
            // changing the floating mode, which this work does not do.
            // `MenuSectionHeader` draws itself only where the style provides for section
            // headings — that is, on the island.
            MenuSectionHeader(title: L10n.t("settings.title", "Settings"))
            SettingToggle(L10n.t("setting.keep.awake", "Keep the Mac awake"),
                          isOn: $appState.keepAwakeEnabled)
            SettingToggle(L10n.t("setting.lid.mode", "Closed-lid mode"), isOn: Binding(
                get: { appState.lidModeEnabled },
                set: { appState.requestLidModeChange(to: $0) }
            ))
            if !LidSleepController.isHelperInstalled {
                Text(L10n.t("settings.lid.password.hint",
                            "Turning this on the first time asks for an administrator password. "
                            + "One-time setup."))
                    .font(.system(size: 10))
                    .foregroundStyle(style.tertiary)
            }
            SettingToggle(L10n.t("setting.sounds", "Sounds"), isOn: $appState.soundsEnabled)
            if !appState.hooksInstalled {
                Button(L10n.t("settings.hooks.install", "Install Claude Code hooks")) {
                    appState.installHooksIfNeeded()
                }
                .font(.system(size: 11))
            }
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .modifier(ToggleTint(color: style.toggleTint))
    }

    /// A section heading. In the panel it is ordinary text at the size it has always
    /// been; in the island menu it is the muted heading style shared by every section.
    /// They have to be told apart because the panel had almost no section headings,
    /// and on black without them the settings list reads as a heap.
    @ViewBuilder
    private func sectionTitle(_ title: String) -> some View {
        if style.separator == nil {
            Text(title).font(.system(size: 12, weight: .medium))
        } else {
            MenuSectionHeader(title: title)
        }
    }
}

/// A settings row with a switch.
///
/// In the panel this is an ordinary `Toggle`, as it has always been: label and
/// switch side by side, width following the text. In the island menu the switches
/// gather into a column at the right edge — otherwise they form a staircase, each
/// one wherever its label happened to end, and three settings rows read as a ragged
/// edge.
///
/// The column is built by hand with an `HStack` and a `Spacer`: a `switch`-styled
/// `Toggle` stretched by a frame pushes not the switch to the right edge but the
/// whole pair together with its label — precisely the wrong thing.
private struct SettingToggle: View {
    let title: String
    @Binding var isOn: Bool
    @Environment(\.menuStyle) private var style

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        self._isOn = isOn
    }

    var body: some View {
        if style.togglesFillWidth {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(style.primary)
                Spacer(minLength: 8)
                Toggle("", isOn: $isOn).labelsHidden()
            }
        } else {
            Toggle(title, isOn: $isOn)
        }
    }
}

/// The system accent blue on the island's toggles would mean what the blue dot in
/// the session list means — "done". So the island's toggles are white while the
/// panel's stay systemic.
private struct ToggleTint: ViewModifier {
    let color: Color?

    func body(content: Content) -> some View {
        if let color {
            content.tint(color)
        } else {
            content
        }
    }
}
