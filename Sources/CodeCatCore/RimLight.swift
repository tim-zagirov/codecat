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
        /// The highlight itself is white; every other stop is the tone.
        public let isWhite: Bool
        public init(location: Double, opacity: Double, isWhite: Bool = false) {
            self.location = location; self.opacity = opacity; self.isWhite = isWhite
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
    /// Near the ends of the lap the highlight's shoulders overtake the 10 %/90 %
    /// stops and the edges; those stops are dropped so the locations stay strictly
    /// ascending, which a gradient needs. `boost` brightens the tone stops for the
    /// hover inhale (§4.3), clamped at full opacity.
    public static func stops(highlight h: Double, boost: Double = 1) -> [Stop] {
        let left = h - 0.14, right = h + 0.14
        var stops = [Stop(location: 0, opacity: 0)]
        if left > 0.1 { stops.append(Stop(location: 0.1, opacity: 0.55)) }
        if left > 0 { stops.append(Stop(location: left, opacity: 0.95)) }
        stops.append(Stop(location: h, opacity: 1, isWhite: true))
        if right < 1 { stops.append(Stop(location: right, opacity: 0.95)) }
        if right < 0.9 { stops.append(Stop(location: 0.9, opacity: 0.55)) }
        stops.append(Stop(location: 1, opacity: 0))
        return stops.map { stop in
            stop.isWhite ? stop : Stop(location: stop.location, opacity: min(1, stop.opacity * boost))
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
