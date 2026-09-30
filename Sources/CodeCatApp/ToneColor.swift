import SwiftUI
import CodeCatCore

/// The four state colours, written once. The island glow, the island dots, the
/// floating badge, the session-row dots and the details panel all read from
/// here, so a green on one surface is the same green everywhere — three copies
/// of this switch used to exist and only agreed by discipline.
enum ToneColor {
    static func color(for tone: MascotTone) -> Color {
        switch tone {
        case .working: return .green
        case .waiting: return .orange
        case .done: return .blue
        case .problem: return .red
        case .sleeping: return Color.white.opacity(0.35)
        }
    }

    /// The island's tones. The island is always black, so these are fixed values —
    /// the dark-mode system colours (spec §7) — and never the adaptive ones: in light
    /// mode `.green` is a darker green, and on black it reads dull.
    static func island(_ tone: MascotTone) -> Color {
        switch tone {
        case .working: return Color(.sRGB, red: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255)
        case .waiting: return Color(.sRGB, red: 0xFF / 255, green: 0x9F / 255, blue: 0x0A / 255)
        case .done: return Color(.sRGB, red: 0x0A / 255, green: 0x84 / 255, blue: 0xFF / 255)
        case .problem: return Color(.sRGB, red: 0xFF / 255, green: 0x45 / 255, blue: 0x3A / 255)
        case .sleeping: return Color.white.opacity(0.35)
        }
    }
}
