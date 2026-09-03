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

            // Тумблер работает в обоих режимах — и для острова, и для плавающего
            // кота. Дубликат этого же пункта есть в меню-баре, и он там обязателен:
            // включи тумблер здесь, пока сессий нет, и маскот вместе с этим меню
            // исчезнет с экрана — выключить обратно было бы неоткуда.
            SettingToggle(L10n.t("setting.hide.when.idle", "Hide the cat when nothing is running"),
                          isOn: $appState.hidesWhenNoSessions)

            MenuSeparator()
            // Заголовок «Облик» рисует сам `SkinPickerView` — он же им и владеет.
            SkinPickerView(appState: appState)

            MenuSeparator()
            // Заголовка «Настройки» в панели никогда не было, и добавлять его
            // сюда — значит менять плавающий режим, чего эта работа не делает.
            // `MenuSectionHeader` рисует себя только там, где заголовки секций
            // предусмотрены стилем, то есть на острове.
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

    /// Заголовок секции. В панели это обычный текст того же кегля, каким он там
    /// был всегда; в меню острова — приглушённый заголовочный стиль, общий для
    /// всех секций. Разводить их приходится потому, что панель заголовков секций
    /// почти не имела, а на чёрном без них список настроек читается как свалка.
    @ViewBuilder
    private func sectionTitle(_ title: String) -> some View {
        if style.separator == nil {
            Text(title).font(.system(size: 12, weight: .medium))
        } else {
            MenuSectionHeader(title: title)
        }
    }
}

/// Строка настройки с переключателем.
///
/// В панели это обычный `Toggle`, каким он там был всегда: подпись и выключатель
/// стоят вплотную, ширина по тексту. В меню острова выключатели собираются в
/// колонку у правого края — иначе они встают лесенкой, каждый там, где кончилась
/// его подпись, и три строки настроек читаются как рваный край.
///
/// Колонка строится руками, `HStack` со `Spacer`: `Toggle` со `switch`-стилем,
/// растянутый рамкой, прижимает к правому краю не выключатель, а всю пару вместе
/// с подписью — то есть ровно не то, что нужно.
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

/// Системный акцентный синий на тумблерах острова означал бы то же, что синяя
/// точка в списке сессий, — «закончил». Поэтому у острова тумблеры белые, а у
/// панели остаются системными.
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
