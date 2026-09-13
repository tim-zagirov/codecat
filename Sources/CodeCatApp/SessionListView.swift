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
    /// re-asserts `NSCursor.pointingHand.set()` on every `onHoverRegion(.active)`
    /// callback — i.e. on every mouse-moved event while inside a clickable row, not
    /// just on entry. See `sessionRow` for the three places `hovered` is cleared
    /// (pointer leaves the row, the row disappears, the panel closes on a click),
    /// each of which lets the arrow win back via the `onChange` below.
    ///
    /// Hover comes from `onHoverRegion`, not SwiftUI's own hover, so it works on the
    /// island's menu, whose window is not key while it was opened by hover (see
    /// `PointerTracker`).
    @State private var hovered: String?

    /// Hover tracking for the *non-interactive* rows, kept separate from `hovered` on
    /// purpose. `hovered` drives the pointing-hand cursor (see its doc comment), which
    /// must never appear over a row that can't be clicked; an unavailable row still
    /// wants to reveal its "can't open its terminal…" hint on hover (S4), so that
    /// hover lands here and touches nothing else.
    @State private var hoveredHint: String?

    @Environment(\.menuStyle) private var style

    /// The single reason to show under the whole list, or nil. It is non-nil only when
    /// every row is unavailable (`.unavailable`) and every one carries the *same*
    /// reason — the case where repeating the hint on each row is pure noise. A routable
    /// row anywhere, or two different reasons, yields nil and the per-row hint returns.
    /// Pure over the routes so it can be unit-tested on fixed values.
    static func sharedUnavailableReason(_ routes: [JumpRoute]) -> UnavailableReason? {
        guard !routes.isEmpty else { return nil }
        var shared: UnavailableReason?
        for route in routes {
            guard case .unavailable(let reason) = route else { return nil }
            if let shared, shared != reason { return nil }
            shared = reason
        }
        return shared
    }

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
        // Computed once per body evaluation and shared by every row:
        //  - `nameCounts` tells a row whether its project name is ambiguous (S22).
        //  - `sharedUnavailable` is the single reason that applies when EVERY row is
        //    unavailable for the SAME reason; in that case the per-row hint is
        //    suppressed and one line is drawn under the whole list (S4). When it is
        //    nil (routable rows present, or reasons differ) each unavailable row
        //    carries its own hint, shown only on hover.
        let nameCounts = Dictionary(
            appState.store.ordered.map { ($0.projectName, 1) }, uniquingKeysWith: +)
        let sharedUnavailable = Self.sharedUnavailableReason(
            appState.store.ordered.map { appState.route(for: $0) })

        VStack(alignment: .leading, spacing: style.blockSpacing) {
            if appState.store.ordered.isEmpty {
                Text(L10n.t("panel.no.sessions", "No active sessions"))
                    .font(.system(size: 12))
                    .foregroundStyle(style.secondary)
            } else {
                ForEach(appState.store.ordered) { session in
                    sessionRow(session, nameShared: (nameCounts[session.projectName] ?? 0) >= 2,
                               suppressRowHint: sharedUnavailable != nil)
                }
                // S4: when the whole list is unavailable for one reason, that reason
                // is stated once here instead of on every row.
                if let reason = sharedUnavailable {
                    Text(JumpMessages.rowHint(for: reason))
                        .font(.system(size: 11))
                        .foregroundStyle(style.tertiary)
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
    /// The default activity strings — the ones a session carries when its activity is
    /// nothing more than a restatement of its status. Drawing "waiting for you ·
    /// waiting for you" (status title · activity) was the M4 finding: when the activity
    /// says only what the coloured dot and status already say, the prefix is dropped.
    private static var defaultActivityStrings: Set<String> {
        [
            L10n.t("activity.session.opened", "open, waiting for a task"),
            L10n.t("activity.waiting", "waiting for you"),
            L10n.t("activity.done", "finished the task"),
            L10n.t("activity.session.stopped", "the session stopped"),
            L10n.t("activity.session.started", "started on the task"),
        ]
    }

    /// M4: `title · activity`, collapsed to `activity` alone when the activity is one
    /// of the default strings or simply repeats the status title. A real activity like
    /// "editing IslandLayout.swift" keeps its "working · " prefix.
    private func secondLineText(_ session: Session) -> String {
        let activity = session.activityDescription
        if Self.defaultActivityStrings.contains(activity) || activity == session.status.title {
            return activity
        }
        return "\(session.status.title) · \(activity)"
    }

    @ViewBuilder
    private func secondLine(_ session: Session) -> some View {
        let status = Text(secondLineText(session))
            .font(.system(size: 11))
            .foregroundStyle(style.secondary)
        // The duration lives in the second line's right column on the island always,
        // and on the panel for every status except `.working` — a working session's
        // duration is drawn by the "running for" third line below, so putting it here
        // too would print it twice. Every other status has no third line now (see
        // `sessionRow`), so this is where its duration has to appear.
        if style.rowLayout == .twoLine || session.status != .working {
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

    /// The SF Symbol naming where a click on this row would land, or nil when the row
    /// is not routable. Trailing the name line (S3), it reads as a quiet destination
    /// hint next to the project name.
    private func routeGlyph(_ route: JumpRoute) -> String? {
        switch route {
        case .terminalTab: return "terminal"
        case .desktopSession: return "bubble.left"
        case .application: return "app"
        case .unavailable: return nil
        }
    }

    @ViewBuilder
    private func sessionRow(_ session: Session, nameShared: Bool, suppressRowHint: Bool) -> some View {
        let route = appState.route(for: session)
        let unavailableReason: UnavailableReason? = {
            if case .unavailable(let reason) = route { return reason }
            return nil
        }()
        // Whether this row is actually clickable. `hovered` is only ever set to
        // this row's id from the interactive branch below, so it can equal
        // `session.id` here only when `hasRoute` was true at the time it was set.
        let hasRoute = unavailableReason == nil

        // S22: when the same project name appears on more than one visible row, the
        // tty distinguishes this one ("codecat · ttys004"). With no tty to add, the
        // bare name stays — a duplicate that at least isn't a lie.
        let displayName: String = {
            guard nameShared, let tty = session.tty, !tty.isEmpty else { return session.projectName }
            return "\(session.projectName) · \(tty)"
        }()

        let content = HStack(alignment: .top, spacing: 8) {
            Circle().fill(color(for: session.status))
                .frame(width: dotSize, height: dotSize)
                .padding(.top, dotTopInset)
            VStack(alignment: .leading, spacing: style.lineSpacing) {
                Text(displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(style.primary)
                secondLine(session)
                // "running for %@" is a claim about a session that is running — only
                // ever drawn for `.working`. A waiting, done, crashed or idle session
                // is not running, and saying so ("running for 0 min" over a session
                // that stopped) was the review finding this removes: those rows carry
                // their honest duration in the second line's right column instead.
                if style.rowLayout == .threeLine && session.status == .working {
                    Text(L10n.f("panel.running.for", "running for %@", duration(session)))
                        .font(.system(size: 10))
                        .foregroundStyle(style.tertiary)
                }
                // S4: with the list-level hint suppressed (reasons differ, or some
                // rows are routable) the per-row hint stays, but only while the pointer
                // is over this row — otherwise every unavailable row shouts the same
                // caption at once. Hover here comes from `hoveredHint`, set by the
                // non-interactive branch below.
                if let reason = unavailableReason, !suppressRowHint, hoveredHint == session.id {
                    Text(JumpMessages.rowHint(for: reason))
                        .font(.system(size: 10))
                        .foregroundStyle(style.tertiary)
                }
            }
            Spacer(minLength: 0)
            // S3: the destination glyph sits at the trailing edge of the name line
            // (the HStack is top-aligned, so it rides level with the project name).
            if hasRoute, let glyph = routeGlyph(route) {
                Image(systemName: glyph)
                    .font(.system(size: 12))
                    .foregroundStyle(style.tertiary)
            }
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
            if hoveredHint == session.id { hoveredHint = nil }
        }

        // Only a row with an actual route gets the tap target and hover/cursor
        // wiring — an unavailable row states its non-interactivity in the view
        // tree instead of installing a tap gesture that a guard then swallows.
        if hasRoute {
            content
                .contentShape(Rectangle())
                .onHoverRegion { phase in
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
            // Not clickable — no tap target and, crucially, no pointing-hand cursor.
            // It still tracks hover, into `hoveredHint`, purely so its "can't open its
            // terminal…" caption can appear only while the pointer is over it (S4).
            content
                .onHoverRegion { phase in
                    switch phase {
                    case .active:
                        if hoveredHint != session.id { hoveredHint = session.id }
                    case .ended:
                        if hoveredHint == session.id { hoveredHint = nil }
                    }
                }
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

    /// The duration each row shows, phrased to match what the session is doing. The
    /// old version always computed `lastActivity - startedAt`, which freezes the
    /// instant a session stops being active: a waiting session read "0 min" and a
    /// stopped one "running for 0 min", both nonsense. Now the clock reflects status.
    /// "now" is read from `Date()` at render; the app ticks `objectWillChange` every
    /// 15 s, so the value keeps counting up on its own.
    ///
    /// - working / idle: how long since it started (`now - startedAt`) — a plain span.
    /// - waiting: how long it has been waiting on you (`now - lastActivity`) → "waiting …".
    /// - done / crashed: how long ago it last did anything (`now - lastActivity`) → "… ago".
    private func duration(_ session: Session) -> String {
        let now = Date()
        switch session.status {
        case .working, .idle:
            return span(from: session.startedAt, to: now)
        case .waitingForYou:
            return L10n.f("duration.waiting", "waiting %@", span(from: session.lastActivity, to: now))
        case .done, .crashed:
            return L10n.f("duration.ago", "%@ ago", span(from: session.lastActivity, to: now))
        }
    }

    /// A bare elapsed span, floored at zero so a slight clock skew never prints a
    /// negative minute count.
    private func span(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        let m = seconds / 60
        if m == 0 {
            return L10n.t("duration.just.now", "just now")
        }
        return m < 60
            ? L10n.f("duration.minutes", "%d min", m)
            : L10n.f("duration.hours.minutes", "%dh %dm", m / 60, m % 60)
    }
}
