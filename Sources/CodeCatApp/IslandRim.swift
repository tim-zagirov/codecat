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
    @Environment(\.islandIsOnScreen) private var onScreen

    var body: some View {
        ZStack {
            if tone != .sleeping {
                TimelineView(.animation(paused: tone != .waiting || reduced || !onScreen)) { context in
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
                Gradient.Stop(color: Self.color(color, towardWhite: $0.white).opacity($0.opacity), location: $0.location)
            }
            IslandRimShape(bodyShape: bodyShape)
                .stroke(LinearGradient(stops: stops,
                                       startPoint: UnitPoint(x: silhouette.minX / width, y: 0.5),
                                       endPoint: UnitPoint(x: silhouette.maxX / width, y: 0.5)),
                        style: StrokeStyle(lineWidth: IslandLayout.rimWidth, lineCap: .round))
        }
    }

    /// The tone mixed `fraction` of the way to white — the band-edge stop that cuts
    /// the highlight's shoulder near the ends of a lap (`RimLight.stops`).
    /// `Color.mix` needs macOS 15, so the mix goes through `NSColor`.
    private static func color(_ tone: Color, towardWhite fraction: Double) -> Color {
        if fraction <= 0 { return tone }
        if fraction >= 1 { return .white }
        guard let mixed = NSColor(tone).usingColorSpace(.sRGB)?.blended(withFraction: fraction, of: .white)
        else { return tone }
        return Color(nsColor: mixed)
    }
}

/// The black shape with its bloom and rim: everything that says the island's state
/// without a word — spec §4.1, §4.3. The bloom casts the tone down onto the
/// wallpaper; under the cursor a black shadow lifts the island off it and the rim
/// brightens.
struct IslandSurface: View {
    let bodyShape: IslandBody
    let tone: MascotTone
    /// The presentation the shape is drawn at — `.compact` for an inhale under Reduce
    /// Motion, which has no inhale.
    let presentation: IslandPresentation

    var body: some View {
        let bloom = RimLight.bloom(for: presentation)
        IslandShape(bodyShape: bodyShape)
            .fill(Color.black)
            .shadow(color: tone == .sleeping ? .clear : ToneColor.island(tone).opacity(bloom.opacity),
                    radius: bloom.radius, x: 0, y: bloom.y)
            .shadow(color: .black.opacity(presentation == .inhaled ? 0.6 : 0), radius: 8, x: 0, y: 3)
            .overlay { IslandRim(bodyShape: bodyShape, tone: tone, boost: RimLight.boost(for: presentation)) }
            .animation(Motion.toneCrossfade, value: tone)
    }
}
