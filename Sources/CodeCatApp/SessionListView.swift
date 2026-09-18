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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

    /// The summary's heading, drawn by the shared section-heading style so the panel
    /// and the island match.
    private var awayLogHeader: some View {
        MenuSectionHeader(title: Self.awayTitle)
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
                if !appState.hooksInstalled {
                    // M6: an empty list with no hooks is not "nothing running" — it is
                    // "not set up yet". Say so, and lead with the one action that fixes
                    // it, rather than a bare line the user can only read past.
                    VStack(spacing: 6) {
                        Text(L10n.t("panel.setup.title", "No sessions yet"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(style.primary)
                        Text(L10n.t("panel.setup.body",
                            "CodeCat needs one setup step before it can see your "
                            + "Claude Code sessions."))
                            .font(.system(size: 11))
                            .foregroundStyle(style.secondary)
                            .multilineTextAlignment(.center)
                        Button(L10n.t("settings.hooks.install", "Set up Claude Code…")) {
                            appState.installHooksIfNeeded()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .padding(.top, 2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else {
                    Text(L10n.t("panel.no.sessions", "No active sessions"))
                        .font(.system(size: 12))
                        .foregroundStyle(style.secondary)
                }
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

    /// The default activity strings — the ones a session carries when its activity is
    /// nothing more than a restatement of its status. Drawing "waiting for you ·
    /// waiting for you" (status title · activity) was the M4 finding: when the activity
    /// says only what the coloured dot and status already say, the prefix is dropped.
    private static var defaultActivityStrings: Set<String> {
        [
            L10n.t("activity.session.opened", "open, waiting for a task"),
            L10n.t("activity.waiting", "waiting for you"),
            L10n.t("activity.done", "finished the task"),
            L10n.t("activity.session.stopped", "ended without finishing"),
            L10n.t("activity.session.started", "started on the task"),
        ]
    }

    /// What the user asked this session for, or nil — when no prompt has been seen
    /// yet, or when the text is switched off (`showsTaskText`). Nil means the line is
    /// not drawn at all: a two-line row where its neighbours have three says "nothing
    /// has been asked here yet" better than any placeholder could.
    private func task(_ session: Session) -> String? {
        guard appState.showsTaskText, let text = session.taskText, !text.isEmpty else { return nil }
        return text
    }

    /// A session waiting for the user, or one that ended badly, has something to say
    /// that outranks what it was asked for: this product exists for the moment an
    /// agent is stuck and nobody noticed. The task keeps its line, underneath.
    private func statusOutranksTask(_ session: Session) -> Bool {
        switch session.status {
        case .waitingForYou, .crashed: return true
        case .idle, .working, .done: return false
        }
    }

    /// `title · activity`, collapsed to `activity` alone when the activity is one of
    /// the default strings, when it merely repeats the status title, or when the
    /// session is working: a working session is announced by the green dot and by
    /// having a task line above it, so "working · editing X" spends a word on nothing.
    /// Every other status keeps its name — "editing api.ts" over a session that
    /// crashed would otherwise read as work still in progress.
    private func statusLineText(_ session: Session) -> String {
        let activity = session.activityDescription
        if Self.defaultActivityStrings.contains(activity) || activity == session.status.title {
            return activity
        }
        if session.status == .working { return activity }
        return "\(session.status.title) · \(activity)"
    }

    /// The status line. `demoted` is the panel's third line — under a task, where the
    /// tool-level activity is quiet proof that something is still happening rather
    /// than the row's headline.
    ///
    /// On the panel the duration sits in this line's right-hand column, whichever of
    /// the two lines it turns out to be, so every row's duration still lines up in one
    /// column. On the island it rides the name line instead (see `sessionRow`), which
    /// leaves the whole width of the second line to the task.
    @ViewBuilder
    private func statusLine(_ session: Session, demoted: Bool) -> some View {
        // Under a task line, a placeholder activity ("started on the task") repeats
        // what the task line has just said in the user's own words. The status's own
        // name is what is left worth saying there — "working", next to the duration.
        let text = demoted && Self.defaultActivityStrings.contains(session.activityDescription)
            ? session.status.title
            : statusLineText(session)
        let status = Text(text)
            .font(.system(size: demoted ? 10 : 11))
            .foregroundStyle(demoted ? style.tertiary : style.secondary)
        if style.rowLayout == .twoLine {
            status
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                status
                Spacer(minLength: 8)
                Text(duration(session))
                    .font(.system(size: 10))
                    .foregroundStyle(style.tertiary)
                    .monospacedDigit()
            }
        }
    }

    /// The task line: the user's own words, wrapped to `lines` and cut with an
    /// ellipsis. Two lines on the panel, one in the island's menu, one when a status
    /// that outranks it has taken the line above.
    private func taskLine(_ text: String, lines: Int) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(style.primary)
            .lineLimit(lines)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The step line, or nil when there is nothing to show: the session is not
    /// working, has no list, its list is finished, or the switch is off.
    private func stepLine(_ session: Session) -> StepLineView? {
        guard appState.showsTaskText, session.status == .working,
              let step = session.currentStep, let progress = session.stepProgress else { return nil }
        return StepLineView(title: step.displayTitle, done: progress.done, total: progress.total,
                            demoted: style.rowLayout == .twoLine)
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

        // Computed once so the row-growth animation below and the view drawn in the
        // VStack agree on exactly the same thing being shown. `stepKey` is nil
        // whenever `step` is nil — not just the step's id — because `stepLine`
        // depends on more than `currentStep`'s identity: `showsTaskText` and
        // `session.status` can also flip the line on or off (a session finishing,
        // or the setting toggled) without `currentStep.id` itself changing, and the
        // row's height needs to animate on that transition too.
        let step = stepLine(session)
        let stepKey = step.map { _ in session.currentStep?.id ?? "" }

        let content = HStack(alignment: .top, spacing: 8) {
            Circle().fill(color(for: session.status))
                .frame(width: dotSize, height: dotSize)
                .padding(.top, dotTopInset)
            VStack(alignment: .leading, spacing: style.lineSpacing) {
                Text(displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(style.primary)
                // The row answers two questions in the order the user needs them.
                // Normally that is "what is this session working on" (the task, in
                // their own words) and then "is it still moving" (the tool-level
                // activity, quietly, with the duration). When the session is waiting
                // on the user or has crashed, the order flips: what they must DO
                // outranks what they asked for, and the task drops to a single line
                // below — on the island, where there are only two lines, it gives way
                // entirely.
                if let task = task(session), !statusOutranksTask(session) {
                    taskLine(task, lines: style.rowLayout == .twoLine ? 1 : 2)
                    // The agent's own plan outranks the tool in hand: "Writing the
                    // parser · 3/5" says where the work is, "editing api.ts" only
                    // that it moves. On the panel the step takes the status line's
                    // place; on the island the row grows a third line for it.
                    if let step {
                        step
                    } else if style.rowLayout == .threeLine {
                        statusLine(session, demoted: true)
                    }
                } else {
                    statusLine(session, demoted: false)
                    if let task = task(session), style.rowLayout == .threeLine {
                        taskLine(task, lines: 1)
                    }
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
            // The trailing edge of the name line — the HStack is top-aligned, so
            // whatever sits here rides level with the project name.
            //
            // On the island that is the duration: with only two lines to spend, the
            // second one belongs to the task in full width, and how long a session has
            // been going is worth more there than a glyph naming where a click lands.
            // On the panel the duration has its own column in the status line, and the
            // glyph keeps this spot (S3).
            if style.rowLayout == .twoLine {
                Text(duration(session))
                    .font(.system(size: 10))
                    .foregroundStyle(style.tertiary)
                    .monospacedDigit()
            } else if hasRoute, let glyph = routeGlyph(route) {
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
        // S9: the row's own `.padding(.horizontal, 4)` insets its text 4 pt past the
        // headings and the away summary. On the island this negative outer padding
        // pulls the whole row (hover rectangle included) back by 4, so the hover keeps
        // its inset while the text column lines up with everything else. The panel
        // keeps its original inset (compensation is 0 there).
        .padding(.horizontal, style.rowInsetCompensation)
        // The row's height changes when a step line appears, disappears, or the
        // task/status line it replaces swaps in its place. Keying on `stepKey`
        // (presence plus id, not the bare step id) catches every path that flips
        // the line on or off — the step itself changing, but also the session
        // leaving `.working`, or `showsTaskText` being toggled — none of which
        // necessarily change `currentStep.id` on their own. Keying on the whole
        // session would also fire the spring for unrelated changes elsewhere on
        // the row, like the duration ticking.
        .animation(reduceMotion ? nil : Motion.reposition, value: stepKey)

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
        default: return ToneColor.color(for: status.tone)
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
    ///
    /// Under a minute every status reads a bare "just now": "just now ago" and
    /// "waiting just now" are not English, and the first of them shipped once.
    private func duration(_ session: Session) -> String {
        let now = Date()
        let justNow = L10n.t("duration.just.now", "just now")
        switch session.status {
        case .working, .idle:
            return span(from: session.startedAt, to: now) ?? justNow
        case .waitingForYou:
            guard let elapsed = span(from: session.lastActivity, to: now) else { return justNow }
            return L10n.f("duration.waiting", "waiting %@", elapsed)
        case .done, .crashed:
            guard let elapsed = span(from: session.lastActivity, to: now) else { return justNow }
            return L10n.f("duration.ago", "%@ ago", elapsed)
        }
    }

    /// A bare elapsed span in whole minutes, floored at zero so a slight clock skew
    /// never prints a negative minute count; nil under a minute.
    private func span(from start: Date, to now: Date) -> String? {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        let m = seconds / 60
        if m == 0 {
            return nil
        }
        return m < 60
            ? L10n.f("duration.minutes", "%d min", m)
            : L10n.f("duration.hours.minutes", "%dh %dm", m / 60, m % 60)
    }
}
