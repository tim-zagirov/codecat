import Foundation

/// Detects the device-pixels-per-drawn-pixel of an upscaled pixel-art cell.
///
/// A Codex pet is drawn at 192×208 but its art is coarser: every drawn pixel is a
/// block of `p × p` identical device pixels. Along any row or column, every run of
/// identical pixels is then a multiple of `p`, so the GCD of all run lengths is a
/// multiple of `p` too — in practice `p` itself, because somewhere in the cell two
/// drawn pixels differ side by side. With `p` known the sheet can be reduced to its
/// native size and rendered exactly like the built-in 16- and 50-pixel packs.
public enum PixelPitch {

    /// Larger blocks than this are not seen in practice; the cap also stops a
    /// nearly uniform cell from claiming its whole width as the pitch.
    public static let maxPitch = 16

    /// `rows` is the cell, row-major, one `UInt32` per pixel (any packing, as long
    /// as equal pixels compare equal). Nil when the cell is empty, uniform, has
    /// single-pixel detail, or no candidate pitch divides both of its sides.
    public static func detect(rows: [[UInt32]]) -> Int? {
        guard let width = rows.first?.count, width > 0 else { return nil }
        let height = rows.count
        var g = 0
        var distinct = Set<UInt32>()

        for row in rows {
            var run = 1
            distinct.insert(row[0])
            for x in 1..<row.count {
                if row[x] == row[x - 1] { run += 1 } else { g = gcd(g, run); run = 1 }
                distinct.insert(row[x])
            }
            g = gcd(g, run)
        }
        for x in 0..<width {
            var run = 1
            for y in 1..<height {
                if rows[y][x] == rows[y - 1][x] { run += 1 } else { g = gcd(g, run); run = 1 }
            }
            g = gcd(g, run)
        }
        guard distinct.count >= 2, g >= 2 else { return nil }

        // The largest candidate that divides the run GCD and both sides of the cell.
        var candidate = min(g, maxPitch)
        while candidate >= 2 {
            if g % candidate == 0, width % candidate == 0, height % candidate == 0 {
                return candidate
            }
            candidate -= 1
        }
        return nil
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var (a, b) = (a, b)
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }
}
