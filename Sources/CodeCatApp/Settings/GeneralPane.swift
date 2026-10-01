import SwiftUI
import CodeCatCore

/// Spec §8, General: how CodeCat shows itself and when.
struct GeneralPane: View {
    @ObservedObject var appState: AppState
    @State private var opensAtLogin = LoginItem.isEnabled

    var body: some View {
        SettingsPaneScaffold(title: SettingsPane.general.title) {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    SettingsLabel(title: L10n.t("settings.show.as", "Show CodeCat as"),
                                  help: NotchScreen.exists
                                      ? L10n.t("settings.show.as.help",
                                               "The island only appears on a built-in display with a notch. "
                                               + "On other displays, choose the floating cat instead.")
                                      : L10n.t("settings.no.notch",
                                               "Island needs a display with a notch. This Mac doesn't have one, so the cat stays floating."))
                    Picker(L10n.t("settings.show.as", "Show CodeCat as"), selection: Binding(
                        get: { appState.showMode },
                        // Refused without a notch: choosing the island there would leave
                        // no cat on screen and no window to explain why.
                        set: { mode in if mode != .island || NotchScreen.exists { appState.showMode = mode } })) {
                        ForEach(ShowMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                SettingsToggle(title: L10n.t("menu.login.item", "Open at login"), isOn: Binding(
                    get: { opensAtLogin },
                    set: { LoginItem.set($0, log: appState.log); opensAtLogin = LoginItem.isEnabled }))
                SettingsToggle(title: L10n.t("setting.hide.when.idle", "Hide when nothing is running"),
                               isOn: $appState.hidesWhenNoSessions)
            }
            Section(L10n.t("settings.section.island", "Island")) {
                LabeledContent {
                    HStack(spacing: 10) {
                        Slider(value: $appState.hoverDelay, in: Motion.hoverDelayRange, step: 0.05)
                            .frame(width: 100)
                        Text(L10n.f("settings.hover.delay.value", "%@ s",
                                    appState.hoverDelay.formatted(.number.precision(.fractionLength(0...2)))))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                } label: {
                    SettingsLabel(title: L10n.t("settings.hover.delay", "Hover delay"),
                                  help: L10n.t("settings.hover.delay.help",
                                               "How long the cursor rests before the island opens."))
                }
                SettingsToggle(title: L10n.t("settings.fullscreen", "Hide in full screen"),
                               help: L10n.t("settings.fullscreen.help", "A waiting agent still peeks."),
                               isOn: $appState.hidesInFullScreen)
            }
            Section {
                SettingsToggle(title: L10n.t("setting.show.task", "Show what each session is doing"),
                               help: L10n.t("setting.show.task.help",
                                            "The task in your words, the agent's current step, and the final message "
                                            + "with its links. Off for a demo or a shared screen."),
                               isOn: $appState.showsTaskText)
            }
        }
    }
}
