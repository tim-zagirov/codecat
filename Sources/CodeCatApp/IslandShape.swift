import SwiftUI
import CodeCatCore

extension IslandBody {
    typealias AnimatableData = AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>>

    /// Width, height, fillet and bottom radius, so a spring moves all four together
    /// (§5.2). 0.4 animated only the height and the bottom radius; the open island
    /// also changes width and fillet, and a snapped width looked like a cut.
    var animatableData: AnimatableData {
        get { AnimatablePair(AnimatablePair(width, height), AnimatablePair(edgeRadius, bottomRadius)) }
        set {
            width = newValue.first.first
            height = newValue.first.second
            edgeRadius = newValue.second.first
            bottomRadius = newValue.second.second
        }
    }
}

/// The island's silhouette, centred at the top of whatever rect it is given — the
/// window's whole canvas. All geometry is `IslandLayout.silhouettePath`; this is the
/// SwiftUI wrapper that lets it animate.
struct IslandShape: Shape {
    var bodyShape: IslandBody

    var animatableData: IslandBody.AnimatableData {
        get { bodyShape.animatableData }
        set { bodyShape.animatableData = newValue }
    }

    func path(in rect: CGRect) -> Path {
        Path(IslandLayout.silhouettePath(canvasWidth: rect.width, body: bodyShape))
            .offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

/// The rim's open path — walls and bottom, never the top — in the same coordinates.
struct IslandRimShape: Shape {
    var bodyShape: IslandBody

    var animatableData: IslandBody.AnimatableData {
        get { bodyShape.animatableData }
        set { bodyShape.animatableData = newValue }
    }

    func path(in rect: CGRect) -> Path {
        Path(IslandLayout.rimPath(canvasWidth: rect.width, body: bodyShape))
            .offsetBy(dx: rect.minX, dy: rect.minY)
    }
}
