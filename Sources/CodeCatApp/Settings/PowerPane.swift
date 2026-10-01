import SwiftUI
import CodeCatCore

/// The line at the top of Power and Claude Code: a dot in the state's colour, what is
/// true now, and one line of detail (Figma 05 "Now" and "Status").
struct SettingsStatusRow: View {
    let tone: MascotTone
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Circle().fill(ToneColor.color(for: tone)).frame(width: 8, height: 8)
            SettingsLabel(title: title, help: detail)
        }
        .padding(.vertical, 4)
    }
}

/// Spec §8, Power: what the Mac is doing now, and the two switches that decide it.
struct PowerPane: View {
    @ObservedObject var appState: AppState

    var body: some View {
        SettingsPaneScaffold(title: SettingsPane.power.title) {
            Section {
                SettingsStatusRow(tone: appState.powerFooter.left == nil ? .sleeping : .working,
                                  title: statusTitle, detail: statusDetail)
            }
            Section {
                SettingsToggle(title: L10n.t("setting.keep.awake", "Keep the Mac awake while agents work"),
                               isOn: $appState.keepAwakeEnabled)
                    // A demo must not hold a real power assertion.
                    .disabled(appState.isDemo)
                LabeledContent {
                    Text(L10n.f("settings.power.floor.value", "%d %% battery",
                                appState.powerManager.batteryFloorPercent))
                        .foregroundStyle(.secondary)
                } label: {
                    SettingsLabel(title: L10n.t("settings.power.floor", "Stop below"),
                                  help: L10n.t("settings.power.floor.help",
                                               "Never holds the Mac awake on a nearly empty battery."))
                }
            }
            Section {
                SettingsToggle(title: L10n.t("setting.lid.mode", "Keep agents running with the lid closed"),
                               help: LidSleepController.isHelperInstalled
                                   ? L10n.t("settings.power.lid.installed",
                                            "Installed: a sudoers rule for two pmset commands and a watchdog that "
                                            + "restores sleep if CodeCat ever quits.")
                                   : L10n.t("settings.lid.password.hint",
                                            "Turning this on the first time asks for an administrator password. "
                                            + "One-time setup."),
                               isOn: Binding(get: { appState.lidModeEnabled },
                                             set: { appState.requestLidModeChange(to: $0) }))
                    // A demo must not start the root-helper install.
                    .disabled(appState.isDemo)
            } header: {
                Text(L10n.t("settings.section.lid", "Closed lid"))
            } footer: {
                // Not Figma's "turning it off … removes both": turning the mode off is
                // instant and removes nothing (decision 7).
                Text(L10n.t("settings.power.lid.footer",
                            "To remove the helper, run "
                            + "/Applications/CodeCat.app/Contents/Resources/uninstall-lid-mode.sh."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusTitle: String {
        switch appState.powerFooter.left {
        case .awake(let agents) where agents == 1:
            return L10n.t("settings.power.awake.one", "Awake — 1 agent working")
        case .awake(let agents):
            return L10n.f("settings.power.awake", "Awake — %d agents working", agents)
        case .sleepsIn(let minutes) where minutes <= 0:
            return L10n.t("settings.power.sleep.now", "Can sleep now")
        case .sleepsIn(let minutes):
            return L10n.f("settings.power.sleep", "Can sleep in %d min", minutes)
        case nil:
            return L10n.t("settings.power.allowed", "Sleep is allowed")
        }
    }

    private var statusDetail: String {
        guard appState.keepAwakeEnabled else {
            return L10n.t("settings.power.off", "CodeCat does not keep the Mac awake.")
        }
        return L10n.f("settings.power.grace", "Sleep comes back %d min after the last one stops.",
                      Int(appState.powerManager.gracePeriod / 60))
    }
}
