import SwiftUI
import AppKit
import CodeCatCore

/// Список активных сессий плюс сводка «пока тебя не было». Вынесен из
/// `DetailsPanelView`, чтобы то же содержимое рисовалось и в меню острова —
/// на другом фоне, но с той же логикой наведения, курсора и перехода.
///
/// Комментарии про курсор и `hovered` переехали сюда дословно: они описывают
/// нетривиальный обход поведения AppKit, а не стиль кода.
///
/// Всё, что здесь показано, вычисляется прямо из `appState` в момент вычисления
/// `body`, поэтому отражает живое состояние само по себе — отдельной подписки
/// на `store`/`awayLog` не нужно.
struct SessionListView: View {
    @ObservedObject var appState: AppState
    var onJump: () -> Void = {}

    /// The id of the clickable row currently under the pointer, or nil. This is the
    /// single source of truth for the hover highlight, and also drives the cursor on
    /// every transition into/out of a row (see the `onChange` below) — there is
    /// deliberately no per-row `NSCursor.push()/pop()`. A push/pop pair relies on
    /// every push eventually being matched by a pop, but a row can vanish out from
    /// under the pointer (its session ends and `ForEach` drops it) without AppKit
    /// ever delivering the matching mouse-exited event, which would leave the
    /// pointing-hand cursor stuck over the whole screen until the app restarts.
    /// `NSCursor.set()` has no such failure mode: it always replaces whatever cursor
    /// is current, so even a missed transition only leaves the cursor wrong until the
    /// next one, never stuck via a corrupted stack.
    ///
    /// `set()` alone is not enough while the pointer keeps moving inside a row,
    /// though: AppKit re-applies its own idea of the cursor (cursor rects /
    /// `cursorUpdate:`, falling back to the arrow) on every mouse-moved event, and
    /// that overrides a `set()` call made on a previous event. So each row also
    /// re-asserts `NSCursor.pointingHand.set()` on every `onContinuousHover(.active)`
    /// callback — i.e. on every mouse-moved event while inside a clickable row, not
    /// just on entry. See `sessionRow` for the three places `hovered` is cleared
    /// (pointer leaves the row, the row disappears, the panel closes on a click),
    /// each of which lets the arrow win back via the `onChange` below.
    @State private var hovered: String?

    @Environment(\.menuStyle) private var style

    /// В панели заголовок сводки — обычный текст того же кегля, что и раньше; в
    /// меню острова у секций есть свой заголовочный стиль.
    @ViewBuilder
    private var awayLogHeader: some View {
        if style.separator == nil {
            Text("Пока тебя не было").font(.system(size: 12, weight: .medium))
        } else {
            MenuSectionHeader(title: "Пока тебя не было")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: style.blockSpacing) {
            if appState.store.ordered.isEmpty {
                Text("Нет активных сессий")
                    .font(.system(size: 12))
                    .foregroundStyle(style.secondary)
            } else {
                ForEach(appState.store.ordered) { session in
                    sessionRow(session)
                }
            }

            if !appState.awayLog.lastSummary.isEmpty {
                MenuSeparator()
                awayLogHeader
                ForEach(appState.awayLog.lastSummary) { entry in
                    // Маркер «• » нужен был, пока сводка шла вплотную к списку
                    // сессий; с заголовком секции и отступом он лишний.
                    Text(style.separator == nil ? "• \(entry.text)" : entry.text)
                        .font(.system(size: 11))
                        .foregroundStyle(style.secondary)
                }
            }
        }
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

    /// Точка статуса. На чёрном 8 pt читаются как клякса, а костыль
    /// `.padding(.top, 5)` под неё подгонялся к трёхстрочной раскладке.
    private var dotSize: CGFloat { style.rowLayout == .twoLine ? 6 : 8 }
    private var dotTopInset: CGFloat { style.rowLayout == .twoLine ? 4 : 5 }

    /// Вторая строка. В двухстрочной раскладке длительность уезжает сюда же и
    /// прижимается вправо: длительности всех сессий выстраиваются в колонку у
    /// правого края — это и есть сетка, которая держит список.
    @ViewBuilder
    private func secondLine(_ session: Session) -> some View {
        let status = Text("\(label(for: session.status)) · \(session.activityDescription)")
            .font(.system(size: 11))
            .foregroundStyle(style.secondary)
        if style.rowLayout == .twoLine {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                status
                Spacer(minLength: 8)
                Text(duration(session))
                    .font(.system(size: 10))
                    .foregroundStyle(style.tertiary)
                    .monospacedDigit()
            }
        } else {
            status
        }
    }

    @ViewBuilder
    private func sessionRow(_ session: Session) -> some View {
        let route = appState.route(for: session)
        let unavailableReason: UnavailableReason? = {
            if case .unavailable(let reason) = route { return reason }
            return nil
        }()
        // Whether this row is actually clickable. `hovered` is only ever set to
        // this row's id from the interactive branch below, so it can equal
        // `session.id` here only when `hasRoute` was true at the time it was set.
        let hasRoute = unavailableReason == nil

        let content = HStack(alignment: .top, spacing: 8) {
            Circle().fill(color(for: session.status))
                .frame(width: dotSize, height: dotSize)
                .padding(.top, dotTopInset)
            VStack(alignment: .leading, spacing: style.lineSpacing) {
                Text(session.projectName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(style.primary)
                secondLine(session)
                if style.rowLayout == .threeLine {
                    Text("длится \(duration(session))")
                        .font(.system(size: 10))
                        .foregroundStyle(style.tertiary)
                }
                if let reason = unavailableReason {
                    Text(JumpMessages.rowHint(for: reason))
                        .font(.system(size: 10))
                        .foregroundStyle(style.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: style.rowRadius)
                .fill(hovered == session.id ? style.rowHover : Color.clear))
        .onDisappear {
            // This row is leaving the hierarchy (its session ended and `ForEach`
            // dropped it) — possibly while still under the pointer, in which case no
            // further hover callback is coming. Clear `hovered` explicitly so the
            // cursor (driven by the `onChange` on `body`) doesn't stay pinned to a
            // row that no longer exists.
            if hovered == session.id { hovered = nil }
        }

        // Only a row with an actual route gets the tap target and hover/cursor
        // wiring — an unavailable row states its non-interactivity in the view
        // tree instead of installing a tap gesture that a guard then swallows.
        if hasRoute {
            content
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active:
                        if hovered != session.id { hovered = session.id }
                        // Reasserted on every mouse-moved event inside the row, not
                        // just on entry: AppKit re-applies its own cursor (cursor
                        // rects / cursorUpdate:, arrow as the fallback) on each such
                        // event, which would otherwise overwrite a `set()` call made
                        // on a prior event within a few pixels of pointer movement.
                        NSCursor.pointingHand.set()
                    case .ended:
                        // Pointer left the row (including leaving the panel/window
                        // entirely from inside it). No further `.active` callbacks
                        // will arrive here to keep re-asserting the pointing hand,
                        // so clearing `hovered` lets the `onChange` on `body` put the
                        // arrow back.
                        if hovered == session.id { hovered = nil }
                    }
                }
                .onTapGesture {
                    // Clear the hover state before the panel closes: `onJump()`
                    // hides the panel immediately, so no further hover callback will
                    // follow this click even though the pointer is still physically
                    // over the row — without this the cursor would stay a pointing
                    // hand after the panel (and its window) is gone.
                    hovered = nil
                    appState.jump(to: session)
                    onJump()
                }
        } else {
            content
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
