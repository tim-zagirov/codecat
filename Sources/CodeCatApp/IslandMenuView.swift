import SwiftUI
import CodeCatCore

/// The open island's list until `IslandExpandedView` replaces it (Part 2, Task 8):
/// the 0.4 session list, on black, reporting its height through
/// `IslandContentHeightKey` so `IslandView` can grow the shape to it.
struct IslandMenuView: View {
    @ObservedObject var appState: AppState
    let width: CGFloat
    /// The tallest the menu's content may be before it scrolls: the room below the
    /// island strip down to the visible frame, less a margin. Handed in by the
    /// controller, which knows the notched screen's geometry.
    let maxContentHeight: CGFloat
    var onJump: () -> Void = {}

    var body: some View {
        // The shape is capped at the screen's room (`IslandLayout.expandedMaxHeight`);
        // a list taller than that scrolls inside it instead of running off the bottom.
        // `scrollBounceBehavior` keeps a short list from rubber-banding.
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SessionListView(appState: appState, onJump: onJump)
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

/// Height of the list as the layout measured it. Not `private`: it is read by
/// `IslandView`, which grows the shape to it.
struct IslandContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
