import SwiftUI
import AppKit
import CodeCatCore

/// The list of active sessions plus the "while you were away" summary. Split out of
/// `DetailsPanelView` so the same content can be drawn in the island menu too — on a
/// different background, but with the same hover, cursor and jump behaviour.
///
/// The comments about the cursor and `hovered` moved here verbatim: they describe a
/// non-obvious workaround for AppKit's behaviour, not a matter of code style.
///
/// Everything here is computed straight from `appState` while `body` runs, so it
/// reflects live state on its own — no separate subscription to `store`/`awayLog` is
/// needed.
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

    private static var awayTitle: String { L10n.t("panel.away.title", "While you were away") }

    /// In the panel the summary's heading is ordinary text at the size it always was;
    /// in the island menu, sections have a heading style of their own.
    @ViewBuilder
    private var awayLogHeader: some View {
        if style.separator == nil {
            Text(Self.awayTitle).font(.system(size: 12, weight: .medium))
        } else {
            MenuSectionHeader(title: Self.awayTitle)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: style.blockSpacing) {
            if appState.store.ordered.isEmpty {
                Text(L10n.t("panel.no.sessions", "No active sessions"))
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
                    // The "• " marker was needed while the summary ran flush against
                    // the session list; with a section heading and padding it is surplus.
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

    /// The status dot. On black, 8 pt reads as a blob, and the `.padding(.top, 5)`
    /// crutch under it was tuned to the three-line layout.
    private var dotSize: CGFloat { style.rowLayout == .twoLine ? 6 : 8 }
    private var dotTopInset: CGFloat { style.rowLayout == .twoLine ? 4 : 5 }

    /// The second line. In the two-line layout the duration moves here too and is
    /// pushed right: every session's duration lines up in a column at the right edge —
    /// that column is the grid holding the list together.
    @ViewBuilder
    private func secondLine(_ session: Session) -> some View {
        let status = Text("\(session.status.title) · \(session.activityDescription)")
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
                    Text(L10n.f("panel.running.for", "running for %@", duration(session)))
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
        // Grey: the session is open but nothing is happening — exactly what the
        // sleeping cat and the empty counter say.
        case .idle: return .secondary
        case .working: return .green
        case .waitingForYou: return .orange
        case .done: return .blue
        case .crashed: return .red
        }
    }

    private func duration(_ session: Session) -> String {
        let seconds = Int(session.lastActivity.timeIntervalSince(session.startedAt))
        let m = seconds / 60
        return m < 60
            ? L10n.f("duration.minutes", "%d min", m)
            : L10n.f("duration.hours.minutes", "%dh %dm", m / 60, m % 60)
    }
}
