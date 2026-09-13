import XCTest
@testable import CodeCatCore

/// Codex pets are pixel art drawn at 192×208 with several device pixels per drawn
/// pixel. The pitch is the GCD of every run of identical pixels, along rows and
/// along columns; a cell of genuinely single-pixel detail has pitch 1 and no answer.
final class PixelPitchTests: XCTestCase {

    /// A small pattern that no two neighbours share, upscaled by `pitch`.
    private func cell(pattern: [[UInt32]], pitch: Int) -> [[UInt32]] {
        pattern.flatMap { row -> [[UInt32]] in
            let wide = row.flatMap { Array(repeating: $0, count: pitch) }
            return Array(repeating: wide, count: pitch)
        }
    }

    private let checker: [[UInt32]] = [
        [1, 2, 3, 4],
        [2, 3, 4, 1],
        [3, 4, 1, 2],
        [4, 1, 2, 3],
    ]

    func testUpscaledPatternsReportTheirPitch() {
        XCTAssertEqual(PixelPitch.detect(rows: cell(pattern: checker, pitch: 4)), 4)
        XCTAssertEqual(PixelPitch.detect(rows: cell(pattern: checker, pitch: 8)), 8)
        XCTAssertEqual(PixelPitch.detect(rows: cell(pattern: checker, pitch: 3)), 3)
    }

    func testSinglePixelDetailHasNoPitch() {
        XCTAssertNil(PixelPitch.detect(rows: checker))
    }

    /// One stray device pixel breaks every run through it: not pixel art any more.
    func testAStrayPixelDefeatsDetection() {
        var rows = cell(pattern: checker, pitch: 4)
        rows[5][6] = 99
        XCTAssertNil(PixelPitch.detect(rows: rows))
    }

    /// A uniform cell has runs as long as its sides and tells us nothing.
    func testUniformCellHasNoPitch() {
        let flat = Array(repeating: Array(repeating: UInt32(0), count: 32), count: 16)
        XCTAssertNil(PixelPitch.detect(rows: flat))
    }

    /// Runs that are all multiples of 32 still mean pixel art; the pitch is capped
    /// at 16 and must divide the cell.
    func testHugePitchIsCappedToADivisor() {
        XCTAssertEqual(PixelPitch.detect(rows: cell(pattern: [[1, 2], [2, 1]], pitch: 32)), 16)
    }

    /// Padding that is not a multiple of the drawn pixel breaks the runs through
    /// it: an odd strip next to a pitch-4 cell drags the GCD to 1, and the sheet
    /// falls back to smooth scaling rather than being reduced by a wrong pitch.
    func testOddPaddingDefeatsDetection() {
        var rows = cell(pattern: checker, pitch: 4)          // 16×16
        rows = rows.map { $0 + [0, 0, 0] }                    // 19 wide, runs of 3 at the edge
        XCTAssertNil(PixelPitch.detect(rows: rows))
    }

    func testEmptyInputHasNoPitch() {
        XCTAssertNil(PixelPitch.detect(rows: []))
        XCTAssertNil(PixelPitch.detect(rows: [[]]))
    }
}
