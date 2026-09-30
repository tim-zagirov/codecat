import SwiftUI
import CodeCatCore

/// What the island shows and the numbers it is drawn with — shared by
/// `IslandController`, which decides, and `IslandView`, which draws. One object for
/// the island's whole life: 0.4 rebuilt the root view on every state change, and the
/// view's own state (the list's measured height, the content's fade) had to be
/// defended against every rebuild.
final class IslandModel: ObservableObject {
    @Published var presentation: IslandPresentation = .compact
    @Published var metrics = IslandMetrics.zero
    /// The open body's height as the view laid it out; the controller's hover and
    /// click outline for the open island.
    var onExpandedHeight: (CGFloat) -> Void = { _ in }
    /// A card's jump started: the island closes.
    var onJump: () -> Void = {}
    /// "•••" was pressed.
    var onSettings: () -> Void = {}
    /// Connect… on the first-run card was pressed.
    var onConnect: () -> Void = {}
}

/// The notched screen's numbers, as the view needs them.
struct IslandMetrics: Equatable {
    var notchWidth: CGFloat
    var wingWidth: CGFloat
    /// The compact island's height — the notch's.
    var stripHeight: CGFloat
    var spriteSize: CGSize
    /// The tallest the open body may be on this screen (§5.2).
    var expandedMaxHeight: CGFloat

    /// Both wings and the notch.
    var compactBody: CGSize { CGSize(width: 2 * wingWidth + notchWidth, height: stripHeight) }

    static let zero = IslandMetrics(notchWidth: 0, wingWidth: 0, stripHeight: 0, spriteSize: .zero,
                                    expandedMaxHeight: 0)
}
