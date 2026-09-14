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
        Group {
            // S5: on the island the skins and settings tuck behind disclosures so a
            // hover shows the sessions and little else; the roomy floating panel keeps
            // everything laid out at once. `style.separator != nil` is the island, as
            // everywhere else in this file.
            if style.separator != nil {
                islandSections
            } else {
                panelSections
            }
        }
        .toggleStyle(.switch)
        // S16: the mini switch's on/off differed only by track luminance and was hard
        // to read on the island's black. `.small` gives the knob visible travel there.
        // The panel keeps the mini size it always had.
        .controlSize(style.separator != nil ? .small : .mini)
        .modifier(ToggleTint(color: style.toggleTint))
    }

    /// The floating panel: every block laid out at once, top to bottom.
    private var panelSections: some View {
        VStack(alignment: .leading, spacing: style.blockSpacing) {
            viewPicker
            MenuSeparator()
            // `SkinPickerView` draws the "Skin" heading itself — it owns it.
            SkinPickerView(appState: appState)
            MenuSeparator()
            // The section heading now draws on both surfaces, so the panel gains the
            // "Settings" heading it lacked and the two menus read as one design.
            MenuSectionHeader(title: L10n.t("settings.title", "Settings"))
            settingsControls
        }
    }

    /// The island menu: skins and settings each behind a collapsible disclosure,
    /// closed by default. The disclosure row reuses the chevron + hover-highlight
    /// pattern from `SkinPickerView`'s credits row.
    private var islandSections: some View {
        VStack(alignment: .leading, spacing: style.blockSpacing) {
            disclosureHeader(title: L10n.t("island.section.skins", "Skins"),
                             isExpanded: appState.islandSkinsExpanded) {
                appState.islandSkinsExpanded.toggle()
            }
            if appState.islandSkinsExpanded {
                // The disclosure row is the heading here, so the picker drops its own.
                SkinPickerView(appState: appState, showsHeader: false)
            }

            MenuSeparator()
            disclosureHeader(title: L10n.t("settings.title", "Settings"),
                             isExpanded: appState.islandSettingsExpanded) {
                appState.islandSettingsExpanded.toggle()
            }
            if appState.islandSettingsExpanded {
                viewPicker
                settingsControls
            }
        }
    }

    /// The "View" mode picker and its notchless-Mac hint. Leads the settings on both
    /// surfaces.
    @ViewBuilder private var viewPicker: some View {
        sectionTitle(L10n.t("settings.view", "View"))
        // On a notchless Mac the guarded binding refuses `.island`: the segment
        // stays visible but tapping it does nothing, so the cat is never stranded
        // by removing both the floating mascot and the panel that holds this hint.
        // On a notched Mac the setter is a plain passthrough and both modes work.
        Picker(L10n.t("settings.view", "View"), selection: Binding(
            get: { appState.displayMode },
            set: { newValue in
                if newValue == .island, !Self.hasScreenWithNotch { return }
                appState.displayMode = newValue
            }
        )) {
            ForEach(MascotDisplayMode.allCases, id: \.self) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()

        // S15: the island is not free real estate — its wings sit over the menu
        // bar. Say so plainly where the mode is chosen, but only on the island
        // itself (`style.separator != nil`); the floating panel has nothing to
        // warn about.
        if style.separator != nil {
            Text(L10n.t("settings.island.menubar",
                        "The island covers a little of the menu bar on each side of the notch."))
                .font(.system(size: 11))
                .foregroundStyle(style.secondary)
        }

        // Shown up front whenever there is no notch — not only after a (now
        // blocked) switch — so the user learns why "Island" does nothing before
        // reaching for it.
        if !Self.hasScreenWithNotch {
            Text(L10n.t("settings.no.notch",
                        "Island needs a display with a notch. This Mac doesn't have one, so the cat stays floating."))
                .font(.system(size: 11))
                .foregroundStyle(style.secondary)
        }
    }

    /// The settings toggles and the hooks button, under the "Settings" heading.
    @ViewBuilder private var settingsControls: some View {
        // M6: while hooks are missing CodeCat does nothing, so the one control that
        // fixes that leads the section and is the prominent one — not an 11 pt
        // afterthought at the very bottom. `.controlSize(.small)` is applied on the
        // button itself so the section's `.controlSize` doesn't shrink this
        // borderedProminent button back down.
        if !appState.hooksInstalled {
            Button(L10n.t("settings.hooks.install", "Set up Claude Code…")) {
                appState.installHooksIfNeeded()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        // C11: the "hide when idle" toggle sits with the other settings rather than
        // up by the View picker, so it reads next to the settings it belongs with.
        // The menu bar carries a duplicate of it, and that duplicate is mandatory:
        // turn this on here while there are no sessions and the mascot disappears
        // along with this very menu, leaving nowhere to turn it off.
        SettingToggle(L10n.t("setting.hide.when.idle", "Hide the cat when nothing is running"),
                      isOn: $appState.hidesWhenNoSessions)
        SettingToggle(L10n.t("setting.keep.awake", "Keep the Mac awake while agents work"),
                      isOn: $appState.keepAwakeEnabled)
        SettingToggle(L10n.t("setting.lid.mode", "Keep agents running with the lid closed"), isOn: Binding(
            get: { appState.lidModeEnabled },
            set: { appState.requestLidModeChange(to: $0) }
        ))
        if !LidSleepController.isHelperInstalled {
            Text(L10n.t("settings.lid.password.hint",
                        "Turning this on the first time asks for an administrator password. "
                        + "One-time setup."))
                .font(.system(size: 11))
                .foregroundStyle(style.secondary)
        }
        SettingToggle(L10n.t("setting.sounds", "Play a sound when an agent needs you"), isOn: $appState.soundsEnabled)
    }

    /// A collapsible section header: a chevron that turns and a muted heading, the
    /// whole row pressable with the shared hover highlight. Mirrors the credits
    /// disclosure in `SkinPickerView` so the island's disclosures behave alike.
    private func disclosureHeader(title: String, isExpanded: Bool,
                                  toggle: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(style.tertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .animation(.easeOut(duration: 0.15), value: isExpanded)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(style.tertiary)
            Spacer(minLength: 0)
        }
        .hoverHighlight()
        .onTapGesture(perform: toggle)
        .accessibilityAddTraits(.isButton)
        // The hover highlight insets its row 4 pt; pull the row back by the same 4 so
        // its chevron column lines up with the headings below it (S9).
        .padding(.horizontal, style.rowInsetCompensation)
    }

    /// A section heading, drawn by the shared muted heading style so the panel and
    /// the island read as one design.
    private func sectionTitle(_ title: String) -> some View {
        MenuSectionHeader(title: title)
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
