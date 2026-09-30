import SwiftUI
import CodeCatCore

/// Spec §8, Alerts: which peeks open by themselves, and the sound. The sound does not
/// depend on the peeks (§6.2): turning peeks off must not silently turn sounds off.
struct AlertsPane: View {
    @ObservedObject var appState: AppState

    var body: some View {
        SettingsPaneScaffold(title: SettingsPane.alerts.title) {
            Section(L10n.t("settings.section.peek", "Peek")) {
                SettingsToggle(title: L10n.t("setting.peek.waiting", "When an agent waits for you"),
                               help: L10n.t("setting.peek.waiting.help", "The island opens for 3 s and says who and why."),
                               isOn: $appState.peekOnWaiting)
                SettingsToggle(title: L10n.t("setting.peek.crash", "When a session crashes"),
                               isOn: $appState.peekOnCrash)
                SettingsToggle(title: L10n.t("setting.peek.done", "When a turn is done"),
                               help: L10n.t("setting.peek.done.help",
                                            "A softer 1.5 s peek with the first line of the result."),
                               isOn: $appState.peekOnDone)
            }
            Section {
                SettingsToggle(title: L10n.t("setting.sounds", "Play a sound when an agent needs you"),
                               isOn: $appState.soundsEnabled)
            } header: {
                Text(L10n.t("settings.section.sound", "Sound"))
            } footer: {
                Text(L10n.t("settings.alerts.footer", "CodeCat never sends a system notification on top of a peek."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
