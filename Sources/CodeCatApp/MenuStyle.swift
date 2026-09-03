import SwiftUI

/// How the menu looks. The same session list, the same grid of skins and the same
/// toggles are drawn on two completely different surfaces, and their legibility
/// rules are opposites.
///
/// The floating panel sits on `.regularMaterial` — a system background — where
/// system semantic colours (`.secondary`, `.tertiary`, `Color.primary`, the accent
/// blue) are exactly right: they adapt to light and dark on their own.
///
/// The island menu sits on **pure black** — not a system background but a colour
/// matched to the display's physical notch. System semantics lie there:
/// `.secondary` believes it knows the background and, in light mode, produces
/// near-black text on black. So the island states its whites as numbers, colour
/// lives only in the status dots, and selection is a white border — the system
/// blue is already spoken for by the "done" status.
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

    /// The floating panel. Every value is copied one for one from how it looked
    /// before styles existed: this preset has to be identical to the old appearance,
    /// or splitting the two surfaces apart was pointless.
    static let panel = MenuStyle(
        rowLayout: .threeLine,
        primary: .primary,
        secondary: .secondary,
        tertiary: Color.primary.opacity(0.4),
        rowHover: Color.primary.opacity(0.08),
        rowRadius: 6,
        cellFill: Color.primary.opacity(0.05),
        cellHover: Color.primary.opacity(0.05),
        cellSelected: Color.primary.opacity(0.05),
        cellRadius: 6,
        cellSize: CGSize(width: 34, height: 34),
        cellSpacing: 8,
        selectionBorder: .accentColor,
        selectionBorderWidth: 2,
        separator: nil,
        toggleTint: nil,
        togglesFillWidth: false,
        padding: 14,
        blockSpacing: 10,
        lineSpacing: 2)

    /// The island menu. Its whites are stated as numbers: the background here is
    /// not a system one, and system semantics know nothing about it.
    static let island = MenuStyle(
        rowLayout: .twoLine,
        primary: .white,
        secondary: Color.white.opacity(0.62),
        tertiary: Color.white.opacity(0.38),
        rowHover: Color.white.opacity(0.08),
        rowRadius: 6,
        cellFill: Color.white.opacity(0.06),
        cellHover: Color.white.opacity(0.10),
        cellSelected: Color.white.opacity(0.16),
        cellRadius: 8,
        cellSize: CGSize(width: 60, height: 40),
        cellSpacing: 6,
        selectionBorder: .white,
        selectionBorderWidth: 1,
        separator: Color.white.opacity(0.12),
        toggleTint: .white,
        togglesFillWidth: true,
        padding: 12,
        blockSpacing: 8,
        lineSpacing: 4)
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

/// Heading for a meaningful section of the menu. The panel never had these — its
/// sections were separated by lines alone — so this view draws nothing until the
/// style asks: `title` appears only where headings are part of the design.
struct MenuSectionHeader: View {
    let title: String
    @Environment(\.menuStyle) private var style

    var body: some View {
        if style.separator != nil {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(style.tertiary)
        }
    }
}
