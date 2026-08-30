import SwiftUI
import AppKit
import CodeCatCore

/// Everything shown here is derived straight from `appState` at `body` evaluation
/// time, so it reflects live state automatically whenever `AppState.objectWillChange`
/// fires (see its doc comment) — no separate observation of `store`/`awayLog` needed.
struct DetailsPanelView: View {
    @ObservedObject var appState: AppState

    /// Called after a jump is started, so the panel can close itself: the user asked
    /// to be somewhere else.
    var onJump: () -> Void = {}

    /// The id of the clickable row currently under the pointer, or nil. This is the
    /// single source of truth for both the hover highlight and the pointing-hand
    /// cursor (see the `onChange` below) — there is deliberately no per-row
    /// `NSCursor.push()/pop()`. A push/pop pair relies on every push eventually being
    /// matched by a pop, but a row can vanish out from under the pointer (its session
    /// ends and `ForEach` drops it) without AppKit ever delivering the matching
    /// mouse-exited event, which would leave the pointing-hand cursor stuck over the
    /// whole screen until the app restarts. `NSCursor.set()` has no such failure mode:
    /// it always replaces whatever cursor is current, so even a missed transition
    /// only leaves the cursor wrong until the next one, never stuck via a corrupted
    /// stack.
    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CodeCat").font(.headline)

            if appState.store.ordered.isEmpty {
                Text("Нет активных сессий")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(appState.store.ordered) { session in
                    sessionRow(session)
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
        // The single place the cursor is ever touched: whenever `hovered` changes —
        // for whatever reason (pointer moved, row disappeared, a jump was clicked) —
        // the cursor is brought in sync with it. See `hovered`'s doc comment for why
        // this replaces per-row push()/pop().
        .onChange(of: hovered) { _, newValue in
            if newValue != nil {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }

    @ViewBuilder
    private func sessionRow(_ session: Session) -> some View {
        let route = appState.route(for: session)
        let unavailableReason: UnavailableReason? = {
            if case .unavailable(let reason) = route { return reason }
            return nil
        }()

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
                if let reason = unavailableReason {
                    Text(JumpMessages.rowHint(for: reason))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hovered == session.id && unavailableReason == nil
                      ? Color.primary.opacity(0.08) : Color.clear))
        .onHover { inside in
            guard unavailableReason == nil else { return }
            // Order-independent under fast pointer movement between two adjacent
            // rows: whichever row's `true` arrives last wins the highlight, and a
            // stale `false` (arriving after the pointer already entered the next
            // row) is a no-op because `hovered` no longer equals this row's id.
            hovered = inside ? session.id : (hovered == session.id ? nil : hovered)
        }
        .onDisappear {
            // This row is leaving the hierarchy (its session ended and `ForEach`
            // dropped it) — possibly while still under the pointer, in which case no
            // `onHover(false)` is coming. Clear `hovered` explicitly so the cursor
            // (driven by the `onChange` on `body`) doesn't stay pinned to a row that
            // no longer exists.
            if hovered == session.id { hovered = nil }
        }
        .onTapGesture {
            guard unavailableReason == nil else { return }
            // Clear the hover state before the panel closes: `onJump()` hides the
            // panel immediately, so no `onHover(false)` will follow this click even
            // though the pointer is still physically over the row.
            hovered = nil
            appState.jump(to: session)
            onJump()
        }
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
