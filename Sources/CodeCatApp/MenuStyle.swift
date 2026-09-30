import SwiftUI

/// How the menu looks. The same session list, the same grid of skins and the same
/// toggles are drawn on two completely different surfaces, and their legibility
/// rules are opposites.
///
/// The floating panel sits on `.regularMaterial` — a system background — where
/// system semantic colours (`.secondary`, `.tertiary`, `Color.primary`, the accent
/// blue) are exactly right: they adapt to light and dark on their own.
///
/// `.island` is for **pure black** — not a system background but a colour matched
/// to the display's physical notch. System semantics lie there: `.secondary`
/// believes it knows the background and, in light mode, produces near-black text on
/// black. So the island states its whites as numbers, colour lives only in the
/// status dots, and selection is a white border — the system blue is already spoken
/// for by the "done" status. The 0.4 island menu drew with it; the 0.5 island draws
/// with `IslandPalette` and has no menu, so nothing sets `.island` any more, and it
/// leaves with `SettingsSectionView`'s island branch in Part 3.
///
/// The style travels through `Environment` rather than as a parameter on every
/// view: it is needed all the way down, to the session row and the skin cell, and
/// threading it by hand through every level means forgetting it somewhere.
struct MenuStyle {

    /// How a session row is laid out.
    enum RowLayout {
        /// Three lines: project / status · activity / duration. The floating
        /// panel's layout, as it has been from the start.
        case threeLine
        /// Two lines: the project, and under it status · activity on the left with
        /// the duration pushed right. The durations line up in a column at the
        /// right edge — that column is the grid holding the list together.
        case twoLine
    }

    var rowLayout: RowLayout

    // MARK: - Text

    /// What people are looking for: the project name, the count, a toggle's label.
    var primary: Color
    /// What explains it: status, activity.
    var secondary: Color
    /// Reference: duration, hints, section headings, an unavailable row.
    var tertiary: Color

    // MARK: - Surfaces

    /// The session row under the cursor.
    var rowHover: Color
    var rowRadius: CGFloat
    /// The skin cell's background, and its states.
    var cellFill: Color
    var cellHover: Color
    var cellSelected: Color
    var cellRadius: CGFloat
    /// Size of a skin cell and the gap between cells. The cell is wider than it is
    /// tall: these cats are four-legged and low, and in a square they float in space.
    var cellSize: CGSize
    var cellSpacing: CGFloat
    /// A chip's fill, and the fill while the cursor is over it.
    var chipFill: Color
    var chipHover: Color
    /// The track a progress or level bar sits in.
    var barTrack: Color
    /// Outline of the selected skin.
    var selectionBorder: Color
    var selectionBorderWidth: CGFloat
    /// Separator colour and weight. `nil` means use the system `Divider()`.
    var separator: Color?
    /// Colour of a toggle that is on. `nil` means the system accent.
    var toggleTint: Color?
    /// Whether a toggle's row stretches the full width. Without this a `Toggle`
    /// shrinks to fit its own label, and the switches end up in a staircase — each
    /// one wherever its text happened to end. A right-hand column lines them up.
    var togglesFillWidth: Bool

    // MARK: - Spacing

    /// The form's margins.
    var padding: CGFloat
    /// Between blocks that mean different things.
    var blockSpacing: CGFloat
    /// Between lines of text within a block.
    var lineSpacing: CGFloat

    /// How far a pressable line's container is pulled back horizontally so its text
    /// column lines up with the headings and tiles, while its hover rectangle keeps
    /// the 4 pt inset `HoverHighlight` and `sessionRow` add. The island states this as
    /// a single left margin (S9); the panel keeps its original inset, so it is zero
    /// there. Only defined where sections carry headings — that is, the island.
    var rowInsetCompensation: CGFloat { separator != nil ? -4 : 0 }

    /// The floating panel. Every value is copied one for one from how it looked
    /// before styles existed: this preset has to be identical to the old appearance,
    /// or splitting the two surfaces apart was pointless.
    static let panel = MenuStyle(
        rowLayout: .threeLine,
        primary: .primary,
        secondary: .secondary,
        tertiary: Color.primary.opacity(0.62),
        rowHover: Color.primary.opacity(0.08),
        rowRadius: 6,
        cellFill: Color.primary.opacity(0.05),
        // Used to equal `cellFill`, so a hovered tile in the panel looked exactly
        // like an idle one and read as a picture rather than a button.
        cellHover: Color.primary.opacity(0.12),
        cellSelected: Color.primary.opacity(0.05),
        cellRadius: 6,
        cellSize: CGSize(width: 56, height: 40),
        cellSpacing: 8,
        chipFill: Color.primary.opacity(0.07),
        chipHover: Color.primary.opacity(0.14),
        barTrack: Color.primary.opacity(0.10),
        selectionBorder: .primary,
        selectionBorderWidth: 2,
        separator: nil,
        toggleTint: nil,
        togglesFillWidth: true,
        padding: 14,
        blockSpacing: 10,
        lineSpacing: 2)

    /// The 0.4 island menu's style (see the type's comment). Its whites are stated as
    /// numbers: the background here is not a system one, and system semantics know
    /// nothing about it.
    static let island = MenuStyle(
        rowLayout: .twoLine,
        primary: .white,
        secondary: Color.white.opacity(0.62),
        tertiary: Color.white.opacity(0.55),
        rowHover: Color.white.opacity(0.13),
        rowRadius: 6,
        cellFill: Color.white.opacity(0.06),
        cellHover: Color.white.opacity(0.16),
        cellSelected: Color.white.opacity(0.16),
        cellRadius: 8,
        cellSize: CGSize(width: 60, height: 40),
        cellSpacing: 6,
        chipFill: Color.white.opacity(0.10),
        chipHover: Color.white.opacity(0.20),
        barTrack: Color.white.opacity(0.10),
        selectionBorder: .white,
        selectionBorderWidth: 1,
        separator: Color.white.opacity(0.22),
        toggleTint: .white,
        togglesFillWidth: true,
        padding: 12,
        blockSpacing: 8,
        lineSpacing: 4)
}

/// The island's whites and type — spec §7. Stated as numbers for the same reason
/// as `MenuStyle.island`: the island is black whatever the system appearance, and
/// system semantics know nothing about it. Colour lives only in the tones.
enum IslandPalette {
    static let primary = Color.white
    static let secondary = Color.white.opacity(0.62)
    static let tertiary = Color.white.opacity(0.38)
    static let card = Color.white.opacity(0.06)
    static let cardHover = Color.white.opacity(0.10)
    static let hairline = Color.white.opacity(0.08)
    /// Pills, chips, code tokens, the "•••" disc.
    static let pill = Color.white.opacity(0.10)
    static let pillHover = Color.white.opacity(0.20)
    static let barTrack = Color.white.opacity(0.12)
    static let ringTrack = Color.white.opacity(0.16)
    /// The footer's line.
    static let footer = Color.white.opacity(0.50)

    /// Project names.
    static let nameFont = Font.system(size: 15, weight: .semibold)
    /// Task, reason, summary.
    static let bodyFont = Font.system(size: 13)
    /// Code tokens inside a line of body text.
    static let codeFont = Font.system(size: 13, weight: .medium)
    /// Numbers and pill labels.
    static let numberFont = Font.system(size: 12, weight: .semibold)
    /// Time, reasons for a missing route, the footer.
    static let metaFont = Font.system(size: 11, weight: .medium)
}

private struct MenuStyleKey: EnvironmentKey {
    /// The floating panel is the project's original surface, so it is also the
    /// default: a view that declares no style looks the way it always did.
    static let defaultValue = MenuStyle.panel
}

extension EnvironmentValues {
    var menuStyle: MenuStyle {
        get { self[MenuStyleKey.self] }
        set { self[MenuStyleKey.self] = newValue }
    }
}

/// A separator that knows about the style: the system `Divider()` in the panel, a
/// line of a given colour spanning the full width on the island. Full width reads
/// as dividing the slab; inset with margins it reads as list decoration.
struct MenuSeparator: View {
    @Environment(\.menuStyle) private var style

    var body: some View {
        if let color = style.separator {
            Rectangle()
                .fill(color)
                .frame(height: 1)
                .padding(.horizontal, -style.padding)
        } else {
            Divider()
        }
    }
}

/// Heading for a meaningful section of the menu. Drawn the same on both surfaces —
/// a muted 11 pt semibold line — so the panel and the island read as one design
/// rather than two dialects.
struct MenuSectionHeader: View {
    let title: String
    @Environment(\.menuStyle) private var style

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(style.tertiary)
    }
}

// MARK: - Hover

/// Reports the cursor over this view — from the position the AppKit host publishes
/// (`PointerTracker`), not from SwiftUI's own hover, which stays silent in a window
/// that is not key. The island's menu is such a window whenever it was opened by
/// hover, which is exactly when the user first looks at it; the floating panel is
/// key, and uses the same path so that the two surfaces answer "can I press this?"
/// identically.
///
/// Mirrors `onContinuousHover`: `.active(point)` on every move while inside, with
/// the point in this view's local coordinates, and `.ended` once on leaving. A view
/// that vanishes under the cursor (the credits collapsing, a row whose session
/// ended) also gets `.ended`, so callers can clear their state.
///
/// The frame is read in `.global`, which inside an `NSHostingView` is the hosting
/// view's own coordinate space — the space the host publishes the pointer in.
struct HoverRegion: ViewModifier {
    @EnvironmentObject private var pointer: PointerTracker
    let action: (HoverPhase) -> Void
    @State private var inside = false

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { proxy in
                let frame = proxy.frame(in: .global)
                let local: CGPoint? = pointer.location.flatMap { point in
                    frame.contains(point)
                        ? CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
                        : nil
                }
                Color.clear
                    .onChange(of: local, initial: true) { _, point in
                        if let point {
                            inside = true
                            action(.active(point))
                        } else if inside {
                            inside = false
                            action(.ended)
                        }
                    }
                    .onDisappear {
                        if inside {
                            inside = false
                            action(.ended)
                        }
                    }
            })
    }
}

/// The pointing hand while the cursor is over a pressable view.
///
/// The cursor is set with `NSCursor.set()` rather than a `push()/pop()` pair, for the
/// reason spelled out on `SessionListView.hovered`: a missed transition leaves `set()`
/// wrong only until the next event, where a missed `pop()` leaves the hand stuck over
/// the whole screen. `.active` re-asserts the hand whenever AppKit has taken it away
/// (it re-applies its own cursor on a mouse-moved event), which is what the test on
/// `NSCursor.current` detects — the hand is set again exactly when it is gone.
///
/// Re-asserting *unconditionally* would be simpler but costs the tooltips: setting a
/// cursor cancels the tooltip AppKit has scheduled for the view under the pointer, and
/// since the last `set()` lands on the last mouse-moved event before the cursor comes
/// to rest, the skin tiles' `.help(skin.name)` never got to appear. Screenshotted both
/// ways: unconditional `set()` — hand, no tooltip; guarded — hand and tooltip.
///
/// The hand appears only while the window is key (the floating panel, the island's
/// full menu): macOS ignores a cursor set from a non-key window of an inactive app,
/// so on the island's short menu the highlight alone answers the question.
///
/// That is a limit of the platform, not a gap here — measured in a standalone
/// accessory app with two non-key `.nonactivatingPanel`s and a screenshot of the
/// cursor over each. All four routes produced the arrow: `set()` from `mouseMoved`
/// (what this modifier does), `push()` on entry, `disableCursorRects()` before
/// `set()`, and `set()` deferred to the next runloop turn. A tracking area with
/// `.cursorUpdate` and `.activeAlways` — the documented way to own the cursor
/// without cursor rects — was never invoked at all in a non-key window: zero calls
/// while the pointer moved across it.
///
/// The one thing that does work is making the window key, and that is the trade the
/// short menu exists to avoid: a key panel takes keystrokes from whatever the user
/// is typing in (it is how Escape reaches the full menu), so hovering the notch on
/// the way past would swallow what they type. The hand is not worth that.
struct PointingHandOnHover: ViewModifier {
    @State private var inside = false

    func body(content: Content) -> some View {
        content.onHoverRegion { phase in
            switch phase {
            case .active:
                inside = true
                if NSCursor.current !== NSCursor.pointingHand { NSCursor.pointingHand.set() }
            case .ended:
                if inside {
                    inside = false
                    NSCursor.arrow.set()
                }
            }
        }
    }
}

/// Marks a line of the menu as pressable: the style's row highlight while the cursor
/// is over it, plus the pointing hand. One modifier for every clickable line, so the
/// question "can I press this?" is answered the same way on the panel and the island.
struct HoverHighlight: ViewModifier {
    @Environment(\.menuStyle) private var style
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .padding(.vertical, 3)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: style.rowRadius)
                    .fill(hovered ? style.rowHover : Color.clear))
            .contentShape(Rectangle())
            .onHoverRegion { phase in
                if case .active = phase { hovered = true } else { hovered = false }
            }
            .modifier(PointingHandOnHover())
    }
}

extension View {
    func onHoverRegion(_ action: @escaping (HoverPhase) -> Void) -> some View {
        modifier(HoverRegion(action: action))
    }
    func pointingHandOnHover() -> some View { modifier(PointingHandOnHover()) }
    func hoverHighlight() -> some View { modifier(HoverHighlight()) }
}
