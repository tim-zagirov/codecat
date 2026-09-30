import SwiftUI
import CodeCatCore

/// The state on the island's edge — spec §4.1: a 1.5 pt gradient stroke along the
/// walls and the bottom, transparent where the walls meet the screen edge, white
/// where the highlight is. Sleeping draws nothing: a quiet island has no light.
///
/// The highlight stands still at the centre except while an agent waits, when it
/// runs a lap every 2.4 s; the `TimelineView` is paused otherwise, so the loop stops
/// the moment no session waits. A change of tone cross-fades the whole stroke.
struct IslandRim: View {
    let bodyShape: IslandBody
    let tone: MascotTone
    var boost: Double = 1
    @Environment(\.islandReduceMotion) private var reduced

    var body: some View {
        ZStack {
            if tone != .sleeping {
                TimelineView(.animation(paused: tone != .waiting || reduced)) { context in
                    RimStroke(bodyShape: bodyShape, tone: tone,
                              highlight: RimLight.highlight(tone: tone, at: context.date, reduceMotion: reduced),
                              boost: boost)
                }
                .id(tone)
                .transition(.opacity)
            }
        }
        .animation(Motion.toneCrossfade, value: tone)
        .allowsHitTesting(false)
    }
}

/// One frame of the rim. `Animatable`, so while the shape springs open the
/// gradient's ends follow the silhouette's edges frame by frame: the walls must stay
/// at the gradient's transparent ends, or they would flash on mid-spring.
struct RimStroke: View, Animatable {
    var bodyShape: IslandBody
    let tone: MascotTone
    let highlight: Double
    let boost: Double

    var animatableData: IslandBody.AnimatableData {
        get { bodyShape.animatableData }
        set { bodyShape.animatableData = newValue }
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let silhouette = IslandLayout.silhouetteRect(canvasWidth: width, body: bodyShape)
            let color = ToneColor.island(tone)
            let stops = RimLight.stops(highlight: highlight, boost: boost).map {
                Gradient.Stop(color: $0.isWhite ? .white : color.opacity($0.opacity), location: $0.location)
            }
            IslandRimShape(bodyShape: bodyShape)
                .stroke(LinearGradient(stops: stops,
                                       startPoint: UnitPoint(x: silhouette.minX / width, y: 0.5),
                                       endPoint: UnitPoint(x: silhouette.maxX / width, y: 0.5)),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
    }
}
