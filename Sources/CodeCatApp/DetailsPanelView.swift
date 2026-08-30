import SwiftUI
import CodeCatCore

/// Everything shown here is derived straight from `appState` at `body` evaluation
/// time, so it reflects live state automatically whenever `AppState.objectWillChange`
/// fires (see its doc comment) — no separate observation of `store`/`awayLog` needed.
struct DetailsPanelView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CodeCat").font(.headline)

            if appState.store.ordered.isEmpty {
                Text("Нет активных сессий")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(appState.store.ordered) { session in
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(color(for: session.status))
                            .frame(width: 8, height: 8)
                            .padding(.top, 5)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.projectName).font(.system(size: 12, weight: .medium))
                            Text("\(label(for: session.status)) · \(session.activityDescription)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text("длится \(duration(session))")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            if !appState.awayLog.lastSummary.isEmpty {
                Divider()
                Text("Пока тебя не было").font(.system(size: 12, weight: .medium))
                ForEach(appState.awayLog.lastSummary) { entry in
                    Text("• \(entry.text)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

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
        .font(.system(size: 12))
        .padding(14)
        .frame(width: 290, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func color(for status: SessionStatus) -> Color {
        switch status {
        case .working: return .green
        case .waitingForYou: return .orange
        case .done: return .blue
        case .crashed: return .red
        }
    }

    private func label(for status: SessionStatus) -> String {
        switch status {
        case .working: return "работает"
        case .waitingForYou: return "ждёт тебя"
        case .done: return "закончил"
        case .crashed: return "оборвалась"
        }
    }

    private func duration(_ session: Session) -> String {
        let seconds = Int(session.lastActivity.timeIntervalSince(session.startedAt))
        let m = seconds / 60
        return m < 60 ? "\(m) мин" : "\(m / 60) ч \(m % 60) мин"
    }
}
