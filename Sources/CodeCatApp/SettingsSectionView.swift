import SwiftUI
import CodeCatCore

/// Облики и тумблеры. Вынесены из `DetailsPanelView` ради меню острова, где
/// показываются на чёрном фоне и только на полном уровне.
struct SettingsSectionView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Вид").font(.system(size: 12, weight: .medium))
            Picker("Вид", selection: $appState.displayMode) {
                ForEach(MascotDisplayMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if appState.displayMode == .island {
                Toggle("Прятать остров, когда сессий нет", isOn: $appState.islandHidesWhenIdle)
            }

            Divider()

            SkinPickerView(appState: appState)

            Divider()
            Toggle("Не давать маку спать", isOn: $appState.keepAwakeEnabled)
            Toggle("Режим закрытой крышки", isOn: Binding(
                get: { appState.lidModeEnabled },
                set: { appState.requestLidModeChange(to: $0) }
            ))
            if !LidSleepController.isHelperInstalled {
                Text("Первое включение попросит пароль администратора (разовая настройка).")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Toggle("Звуки", isOn: $appState.soundsEnabled)
            if !appState.hooksInstalled {
                Button("Установить хуки Claude Code") {
                    appState.installHooksIfNeeded()
                }
                .font(.system(size: 11))
            }
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
    }
}
