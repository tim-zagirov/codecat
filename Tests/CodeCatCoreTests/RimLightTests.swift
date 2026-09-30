import XCTest
@testable import CodeCatCore

final class RimLightTests: XCTestCase {

    private func assertStops(_ actual: [RimLight.Stop], _ expected: [(Double, Double, Bool)],
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, "\(actual)", file: file, line: line)
        for (stop, (location, opacity, white)) in zip(actual, expected) {
            XCTAssertEqual(stop.location, location, accuracy: 1e-9, file: file, line: line)
            XCTAssertEqual(stop.opacity, opacity, accuracy: 1e-9, file: file, line: line)
            XCTAssertEqual(stop.isWhite, white, file: file, line: line)
        }
    }

    /// Spec §4.1, word for word: 0 % at both ends, 55 % at 10/90 %, 95 % at h ± 0.14, white at h.
    func testTheCentredHighlightHasTheSpecsSevenStops() {
        assertStops(RimLight.stops(highlight: 0.5), [
            (0, 0, false), (0.1, 0.55, false), (0.36, 0.95, false), (0.5, 1, true),
            (0.64, 0.95, false), (0.9, 0.55, false), (1, 0, false),
        ])
    }

    /// At the ends of its lap the highlight's shoulders run past the 10 % stop and
    /// the edge; the stops that would fall out of order are dropped, and no stop
    /// lands in the outer 10 %, where the walls are: a 95 % stop there lit a whole
    /// wall up to the screen edge for a few frames of every lap.
    func testAHighlightAtTheEdgeDropsTheStopsItOvertakes() {
        for step in 0...80 {
            let inner = RimLight.stops(highlight: 0.1 + Double(step) / 100).dropFirst().dropLast()
            XCTAssertTrue(inner.allSatisfy { $0.location >= 0.1 && $0.location <= 0.9 }, "\(inner)")
        }
        // h = 0.2: the shoulder is 0.04 into the band — the 10 % stop is 40 % of the
        // way to the curve's value there, with the spec's step kept just inside it.
        let t = 1 - 0.1 / 0.14
        let edge = RimLight.stops(highlight: 0.2)
        XCTAssertEqual(edge[1].location, 0.1, accuracy: 1e-9)
        XCTAssertEqual(edge[1].opacity, 0.55 + (0.95 + 0.05 * t - 0.55) * 0.4, accuracy: 1e-9)
        XCTAssertEqual(edge[1].white, t * 0.4, accuracy: 1e-9)
        XCTAssertEqual(edge[2].location, 0.1001, accuracy: 1e-9)
        XCTAssertEqual(edge[2].white, t, accuracy: 1e-9)
        assertStops(RimLight.stops(highlight: 0.1), [
            (0, 0, false), (0.1, 1, true), (0.24, 0.95, false), (0.9, 0.55, false), (1, 0, false),
        ])
        assertStops(RimLight.stops(highlight: 0.9), [
            (0, 0, false), (0.1, 0.55, false), (0.76, 0.95, false), (0.9, 1, true), (1, 0, false),
        ])
    }

    func testStopsAreStrictlyAscendingAlongTheWholeLap() {
        for step in 0...80 {
            let h = 0.1 + Double(step) / 100
            let locations = RimLight.stops(highlight: h).map(\.location)
            XCTAssertEqual(locations.first, 0)
            XCTAssertEqual(locations.last, 1)
            for (a, b) in zip(locations, locations.dropFirst()) {
                XCTAssertLessThan(a, b, "h = \(h): \(locations)")
            }
        }
    }

    /// Hover inhale multiplies the tone stops by 1.3, clamped; white stays white.
    func testBoostBrightensTheToneStopsUpToFullOpacity() {
        assertStops(RimLight.stops(highlight: 0.5, boost: 1.3), [
            (0, 0, false), (0.1, 0.715, false), (0.36, 1, false), (0.5, 1, true),
            (0.64, 1, false), (0.9, 0.715, false), (1, 0, false),
        ])
    }

    /// A lap every 2.4 s, from 0.1 to 0.9, read off the clock — so a view rebuilt
    /// halfway through a lap carries on from where it was.
    func testTheWaitingHighlightTravelsALapEvery2point4Seconds() {
        func h(_ t: TimeInterval) -> Double {
            RimLight.highlight(tone: .waiting, at: Date(timeIntervalSinceReferenceDate: t), reduceMotion: false)
        }
        XCTAssertEqual(h(0), 0.1, accuracy: 1e-9)
        XCTAssertEqual(h(0.6), 0.3, accuracy: 1e-9)
        XCTAssertEqual(h(1.2), 0.5, accuracy: 1e-9)
        XCTAssertEqual(h(2.4), 0.1, accuracy: 1e-9)
        XCTAssertEqual(h(2.4 * 1000 + 1.2), 0.5, accuracy: 1e-6)
    }

    func testOnlyWaitingTravelsAndReduceMotionStopsIt() {
        let t = Date(timeIntervalSinceReferenceDate: 0.6)
        XCTAssertEqual(RimLight.highlight(tone: .waiting, at: t, reduceMotion: true), 0.5)
        for tone in [MascotTone.working, .done, .problem, .sleeping] {
            XCTAssertEqual(RimLight.highlight(tone: tone, at: t, reduceMotion: false), 0.5)
        }
    }

    func testBloomAndBoostPerPresentation() {
        XCTAssertEqual(RimLight.bloom(for: .compact), RimLight.Bloom(opacity: 0.32, radius: 10, y: 2))
        XCTAssertEqual(RimLight.bloom(for: .inhaled), RimLight.Bloom(opacity: 0.5, radius: 14, y: 2))
        XCTAssertEqual(RimLight.bloom(for: .expanded), RimLight.Bloom(opacity: 0.40, radius: 14, y: 3))
        XCTAssertEqual(RimLight.boost(for: .inhaled), 1.3)
        XCTAssertEqual(RimLight.boost(for: .compact), 1)
        XCTAssertEqual(RimLight.boost(for: .expanded), 1)
    }
}
