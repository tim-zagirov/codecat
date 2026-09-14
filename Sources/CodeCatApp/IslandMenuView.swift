import SwiftUI
import CodeCatCore

/// How much of the menu is shown.
enum IslandMenuLevel {
    /// Hover: the session list alone. The mouse may have wandered onto the island by
    /// accident, and half a screen of settings in response to that is too much.
    case short
    /// Click: everything the floating panel has.
    case full
}

/// The island menu's content — the content and nothing else.
///
/// No background, no shape, no reveal animation: all of that belongs to
/// `IslandView`, where the island and the menu sit on one backing and are clipped by
/// one silhouette. While the menu was a separate window with its own black
/// background and its own rounded mask, the seam at the join could only be hidden —
/// by matching widths and zeroing the island's radius. One backing removes the seam
/// as a phenomenon.
///
/// The only thing this view reports outward is its height: `IslandView` uses it to
/// know how far to grow the silhouette.
struct IslandMenuView: View {
    @ObservedObject var appState: AppState
    let level: IslandMenuLevel
    let width: CGFloat
    /// The tallest the menu's content may be before it scrolls: the room below the
    /// island strip down to the visible frame, less a margin. Handed in by the
    /// controller, which knows the notched screen's geometry.
    let maxContentHeight: CGFloat
    var onJump: () -> Void = {}

    var body: some View {
        // The silhouette is already clamped to the screen by `IslandLayout.windowFrame`;
        // without a scroll view the content taller than that clamp is simply clipped, and
        // the settings block and hooks button fall off the bottom. Cap the content at the
        // room below the strip and let the overflow scroll. `scrollBounceBehavior` keeps a
        // short menu from rubber-banding, so most menus feel exactly as before.
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SessionListView(appState: appState, onJump: onJump)
                if level == .full {
                    MenuSeparator()
                    SettingsSectionView(appState: appState)
                } else {
                    // S17: the short menu looks complete on its own, and its window is
                    // not key so the cursor stays an arrow — nothing says a click does
                    // more. One quiet line answers both at once.
                    Text(L10n.t("island.more", "Click for skins and settings"))
                        .font(.system(size: 10))
                        .foregroundStyle(MenuStyle.island.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .frame(width: width, alignment: .leading)
            .background(GeometryReader { proxy in
                // The reported height is the content's own, capped: the silhouette must
                // never grow past `maxContentHeight`, or it would run off the screen while
                // the inner scroll view sat idle. When the content fits, this is the
                // content's natural height and the island shrink-wraps to it as before.
                Color.clear.preference(key: IslandContentHeightKey.self,
                                       value: min(proxy.size.height, maxContentHeight))
            })
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: width)
        .frame(maxHeight: maxContentHeight)
        .environment(\.menuStyle, .island)
        // The content is written for the system theme: on a black background it has to
        // consider itself in dark mode, or system elements (the mode picker, the
        // toggles) end up as light slabs on black.
        .environment(\.colorScheme, .dark)
    }
}

/// Height of the menu's content as the layout measured it. Not `private`: it is read
/// by `IslandView`, which owns the reveal animation.
struct IslandContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
