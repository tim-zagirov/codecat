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
    var onJump: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SessionListView(appState: appState, onJump: onJump)
            if level == .full {
                MenuSeparator()
                SettingsSectionView(appState: appState)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(width: width, alignment: .leading)
        .environment(\.menuStyle, .island)
        // The content is written for the system theme: on a black background it has to
        // consider itself in dark mode, or system elements (the mode picker, the
        // toggles) end up as light slabs on black.
        .environment(\.colorScheme, .dark)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: IslandContentHeightKey.self, value: proxy.size.height)
        })
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
