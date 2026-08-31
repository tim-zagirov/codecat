import SwiftUI
import AppKit
import CodeCatCore

/// Облики и тумблеры. Вынесены из `DetailsPanelView` ради меню острова, где
/// показываются на чёрном фоне и только на полном уровне.
///
/// Всё, что здесь показано, вычисляется прямо из `appState` в момент вычисления
/// `body`, поэтому отражает живое состояние само по себе — отдельной подписки
/// на `store`/`awayLog` не нужно.
struct SettingsSectionView: View {
    @ObservedObject var appState: AppState

    /// Экран с вырезом — тот, для которого действительно строится
    /// `IslandLayout.notchRect`, а не тот, у которого просто ненулевой
    /// safe-area-инсет (см. `IslandController.geometry()`): один и тот же
    /// признак «есть вырез» должен использоваться и там, где остров реально
    /// появляется, и здесь, где об этом предупреждают заранее.
    private static var hasScreenWithNotch: Bool {
        NSScreen.screens.contains { screen in
            IslandLayout.notchRect(auxLeft: screen.auxiliaryTopLeftArea,
                                   auxRight: screen.auxiliaryTopRightArea) != nil
        }
    }

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

            if appState.displayMode == .island, !Self.hasScreenWithNotch {
                Text("На этом экране нет выреза — остров не появится.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            // Тумблер виден и в плавающем режиме, хотя там он ни на что не влияет
            // (его читает только `IslandController.setVisible`): спрятанный за
            // `if displayMode == .island`, он запирал бы сам себя — включи его в
            // острове, пока сессий нет, и меню вместе с тумблером исчезает, а
            // достать тумблер больше неоткуда.
            Toggle("Прятать остров, когда сессий нет", isOn: $appState.islandHidesWhenIdle)

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
