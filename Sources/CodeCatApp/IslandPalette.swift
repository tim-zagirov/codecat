import SwiftUI

// The island's fixed whites and fonts, and the hover modifiers the island and the
// floating cat's panel share. Both surfaces are black whatever the system
// appearance, so their colours are numbers rather than system semantics, and both
// live in non-key or non-activating windows, so hover comes from the pointer the
// AppKit host publishes rather than from SwiftUI's own.

/// The island's whites and type — spec §7. Stated as numbers because the island is
/// a fixed black surface whatever the system appearance, and system semantics
/// know nothing about it. Colour lives only in the tones.
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
    /// A peek's project name (Figma 03): one line, so smaller than a card's 15.
    static let peekTitleFont = Font.system(size: 13, weight: .semibold)
    /// Task, reason, summary.
    static let bodyFont = Font.system(size: 13)
    /// Code tokens inside a line of body text.
    static let codeFont = Font.system(size: 13, weight: .medium)
    /// Numbers and pill labels.
    static let numberFont = Font.system(size: 12, weight: .semibold)
    /// Time, reasons for a missing route, the footer.
    static let metaFont = Font.system(size: 11, weight: .medium)
}

// MARK: - Hover

/// Reports the cursor over this view — from the position the AppKit host publishes
/// (`PointerTracker`), not from SwiftUI's own hover, which stays silent in a window
/// that is not key. The island's menu is such a window whenever it was opened by
/// hover, which is exactly when the user first looks at it; so is the floating
/// cat's panel until it is clicked, and both use the same path so that they answer
/// "can I press this?" identically.
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
/// The cursor is set with `NSCursor.set()` rather than a `push()/pop()` pair: a view
/// can vanish under the pointer (its session ends) without AppKit ever delivering the
/// matching exit, and a missed transition leaves `set()` wrong only until the next
/// event, where a missed `pop()` leaves the hand stuck over the whole screen. `.active` re-asserts the hand whenever AppKit has taken it away
/// (it re-applies its own cursor on a mouse-moved event), which is what the test on
/// `NSCursor.current` detects — the hand is set again exactly when it is gone.
///
/// Re-asserting *unconditionally* would be simpler but costs the tooltips: setting a
/// cursor cancels the tooltip AppKit has scheduled for the view under the pointer, and
/// since the last `set()` lands on the last mouse-moved event before the cursor comes
/// to rest, the skin tiles' `.help(skin.name)` never got to appear. Screenshotted both
/// ways: unconditional `set()` — hand, no tooltip; guarded — hand and tooltip.
///
/// The hand appears only while the window is key (the island or the floating panel
/// after a click in it): macOS ignores a cursor set from a non-key window of an inactive app,
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

extension View {
    func onHoverRegion(_ action: @escaping (HoverPhase) -> Void) -> some View {
        modifier(HoverRegion(action: action))
    }
    func pointingHandOnHover() -> some View { modifier(PointingHandOnHover()) }
}
