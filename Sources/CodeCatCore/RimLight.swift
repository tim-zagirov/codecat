import Foundation

/// The island's state drawn on its rim — spec §4.1. 0.4 put a radial glow behind
/// the sprite and it read as a stain; 0.5 lights the rim of the whole island with a
/// gradient stroke along its walls and bottom (`IslandLayout.rimPath`), and casts
/// the tone down onto the wallpaper as a bloom. Pure numbers here; the view maps
/// them to SwiftUI.
public enum RimLight {
    /// One lap of the waiting highlight. The product's only loop, and only while an
    /// agent waits.
    public static let lap: TimeInterval = 2.4

    public struct Stop: Equatable, Sendable {
        public let location: Double
        public let opacity: Double
        /// How far the colour is mixed from the tone toward white: 1 at the highlight,
        /// 0 for the tone stops, in between only where a band edge cuts the highlight's
        /// shoulder (see `stops`).
        public let white: Double
        public var isWhite: Bool { white >= 1 }
        public init(location: Double, opacity: Double, isWhite: Bool = false) {
            self.init(location: location, opacity: opacity, white: isWhite ? 1 : 0)
        }
        public init(location: Double, opacity: Double, white: Double) {
            self.location = location; self.opacity = opacity; self.white = white
        }
    }

    public struct Bloom: Equatable, Sendable {
        public let opacity: Double
        public let radius: Double
        public let y: Double
        public init(opacity: Double, radius: Double, y: Double) {
            self.opacity = opacity; self.radius = radius; self.y = y
        }
    }

    /// Where the highlight sits across the island, 0…1. Still at the centre except
    /// while waiting, when it runs from 0.1 to 0.9 once per `lap`. Read off the
    /// clock rather than kept in view state, so a view rebuilt mid-lap does not
    /// restart it.
    public static func highlight(tone: MascotTone, at date: Date, reduceMotion: Bool) -> Double {
        guard tone == .waiting, !reduceMotion else { return 0.5 }
        let phase = date.timeIntervalSinceReferenceDate / lap
        return 0.1 + 0.8 * (phase - phase.rounded(.down))
    }

    /// The stroke's gradient across the island's width: transparent at both ends —
    /// the walls sit there and fade toward the screen edge — 55 % from 10 % to 90 %,
    /// rising to 95 % 0.14 either side of the highlight and white at it.
    ///
    /// Near the ends of its lap the highlight's shoulder runs into the outer 10 %.
    /// Placing its 95 % stop there lit the whole wall up to the screen edge for a
    /// few frames every lap, then switched it off as the stop left the gradient
    /// (`m2-waiting-lap`: the right wall at h = 0.87, the left at 0.15). So no stop
    /// sits inside the outer 10 % but the transparent end, and the band beyond the
    /// 10 % / 90 % stop always ramps to nothing, which keeps the walls dark. Once the
    /// shoulder has passed that stop, the stop takes the curve's value there — part
    /// of the way from the shoulder to the white — reached over the shoulder's first
    /// 0.1 into the band, with the spec's 0.55 → 0.95 step kept just inside it
    /// meanwhile, so no frame jumps. `boost` brightens the tone stops for the hover
    /// inhale (§4.3), clamped at full opacity.
    public static func stops(highlight h: Double, boost: Double = 1) -> [Stop] {
        let shoulder = 0.14
        /// The stops between the band edge `edge` (0.1 or 0.9) and the highlight, in
        /// ascending order; `inward` is +1 on the left, −1 on the right.
        func band(_ edge: Double, inward: Double) -> [Stop] {
            let s = h - inward * shoulder
            let into = (edge - s) * inward
            if into < 0 {
                let pair = [Stop(location: edge, opacity: 0.55), Stop(location: s, opacity: 0.95)]
                return inward > 0 ? pair : pair.reversed()
            }
            let toHighlight = abs(h - edge)
            guard toHighlight > 1e-9 else { return [] }
            let t = 1 - toHighlight / shoulder
            let curve = 0.95 + 0.05 * t
            let r = min(1, into / 0.1)
            guard r < 1 else { return [Stop(location: edge, opacity: curve, white: t)] }
            let pair = [Stop(location: edge, opacity: 0.55 + (curve - 0.55) * r, white: t * r),
                        Stop(location: edge + inward * 1e-4, opacity: curve, white: t)]
            return inward > 0 ? pair : pair.reversed()
        }
        var stops = [Stop(location: 0, opacity: 0)]
        stops += band(0.1, inward: 1)
        stops.append(Stop(location: h, opacity: 1, isWhite: true))
        stops += band(0.9, inward: -1)
        stops.append(Stop(location: 1, opacity: 0))
        return stops.map { stop in
            stop.isWhite ? stop : Stop(location: stop.location, opacity: min(1, stop.opacity * boost), white: stop.white)
        }
    }

    /// The tone's shadow under the island: soft on the compact strip, stronger under
    /// the cursor and when open, where the shape is larger.
    public static func bloom(for presentation: IslandPresentation) -> Bloom {
        switch presentation {
        case .compact: return Bloom(opacity: 0.32, radius: 10, y: 2)
        case .inhaled: return Bloom(opacity: 0.5, radius: 14, y: 2)
        case .peek, .expanded: return Bloom(opacity: 0.40, radius: 14, y: 3)
        }
    }

    /// The rim brightens under the cursor (§4.3).
    public static func boost(for presentation: IslandPresentation) -> Double {
        presentation == .inhaled ? 1.3 : 1
    }
}
